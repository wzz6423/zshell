import AppKit
import Darwin
import Foundation
import STTextView
@testable import zshell

@main
struct FileTabSaveTests {
    @MainActor private static var checks = 0

    @MainActor private static func check(_ passed: Bool, _ name: String) throws {
        checks += 1
        print("\(passed ? "PASS" : "FAIL") \(name)")
        if !passed { throw NSError(domain: "FileTabSaveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }

    @MainActor private static func loaded(_ path: URL) async throws -> FileTab {
        let file = FileTab(path: path.path)
        for _ in 0..<200 {
            if case .text = file.content { return file }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "FileTabSaveTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "File did not load: \(path.path)"])
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    @MainActor private static func editAndSave(_ file: FileTab, text: String) {
        file.text = text
        file.refreshDirtyState()
        PaneContent.file(file).save()
    }

    @MainActor static func main() async {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        var status: Int32 = 0
        do {
            try await run(root: URL(fileURLWithPath: CommandLine.arguments[1]))
            print("FileTab save: \(checks) checks, 0 failures")
        } catch {
            fputs("\(error)\n", stderr)
            status = 1
        }
        exit(status)
    }

    @MainActor private static func run(root: URL) async throws {
        let fm = FileManager.default
        let settings = AppSettings.shared
        try check(settings.protectEditorSaves, "save conflict protection is enabled by default")
        // Preserve the existing symlink behavior checks with protection disabled.
        settings.protectEditorSaves = false
        func write(_ name: String, _ text: String = "before") throws -> URL {
            let path = root.appendingPathComponent(name)
            try text.write(to: path, atomically: true, encoding: .utf8)
            return path
        }
        func link(_ name: String, to destination: String) throws -> URL {
            let path = root.appendingPathComponent(name)
            try fm.createSymbolicLink(atPath: path.path, withDestinationPath: destination)
            return path
        }

        let target = try write("target.txt")
        let relative = try link("relative.txt", to: "target.txt")
        let file = try await loaded(relative)
        let originalID = file.id
        let view = FileViewerContainerView(file: file)
        view.update(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    palette: .theme(dark: true), wrapLines: false, isFocused: true,
                    showsSource: true, onFocused: {}, onSplit: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        guard let editor = (file.editorView as? NSScrollView)?.documentView as? STTextView else {
            throw NSError(domain: "FileTabSaveTests", code: 3)
        }
        editor.insertText("edited through the real source editor", replacementRange: NSRange(location: 0, length: file.text.utf16.count))
        try check(file.isDirty && file.text == "edited through the real source editor", "mounted source editor writes edits back to FileTab")
        PaneContent.file(file).save()
        try check(isLink(relative), "saving a relative symlink preserves the link")
        try check(try String(contentsOf: target, encoding: .utf8) == file.text, "saving updates the target instead of replacing the link")
        try check(file.path == relative.path && file.id == originalID, "saving retains the tab's displayed path and identity")
        try check(!file.isDirty && file.saveError == nil, "successful save clears the dirty state and error")
        try check(!window.isVisible, "production source editor window stays hidden")

        let absoluteTarget = try write("absolute-target.txt")
        let absolute = try link("absolute.txt", to: absoluteTarget.path)
        let absoluteFile = try await loaded(absolute)
        editAndSave(absoluteFile, text: "absolute edit")
        try check(isLink(absolute) && (try String(contentsOf: absoluteTarget, encoding: .utf8)) == "absolute edit", "absolute links update their targets")

        let chained = try link("chained.txt", to: "relative.txt")
        let chainedFile = try await loaded(chained)
        editAndSave(chainedFile, text: "chain edit")
        try check(isLink(chained) && isLink(relative) && (try String(contentsOf: target, encoding: .utf8)) == "chain edit", "all links in a relative chain survive saving")

        let realDirectory = root.appendingPathComponent("real-directory")
        try fm.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        let child = realDirectory.appendingPathComponent("child.txt")
        try "before".write(to: child, atomically: true, encoding: .utf8)
        let directoryLink = try link("directory-link", to: "real-directory")
        let childFile = try await loaded(directoryLink.appendingPathComponent("child.txt"))
        editAndSave(childFile, text: "directory edit")
        try check(isLink(directoryLink) && (try String(contentsOf: child, encoding: .utf8)) == "directory edit", "symlinked parent directories keep their identity")

        let replacementTarget = try write("replacement.txt")
        let movedLink = root.appendingPathComponent("moved.txt")
        try fm.moveItem(at: relative, to: movedLink)
        file.updatePath(movedLink.path)
        editAndSave(file, text: "renamed link edit")
        try check(isLink(movedLink) && (try String(contentsOf: target, encoding: .utf8)) == "renamed link edit", "renamed tabs save through the link's new path")
        try fm.removeItem(at: movedLink)
        try fm.createSymbolicLink(atPath: movedLink.path, withDestinationPath: "replacement.txt")
        editAndSave(file, text: "retargeted edit")
        try check(isLink(movedLink) && (try String(contentsOf: replacementTarget, encoding: .utf8)) == "retargeted edit", "each save resolves the current link target")
        try check(try String(contentsOf: target, encoding: .utf8) == "renamed link edit", "retargeting does not write the old target")

        try fm.removeItem(at: replacementTarget)
        editAndSave(file, text: "unsaved dangling edit")
        try check(isLink(movedLink) && !fm.fileExists(atPath: replacementTarget.path), "dangling links are neither replaced nor recreated")
        try check(file.isDirty && file.saveError != nil && file.text == "unsaved dangling edit", "dangling-link errors retain the editor's unsaved content")
        try "restored".write(to: replacementTarget, atomically: true, encoding: .utf8)
        PaneContent.file(file).save()
        try check(!file.isDirty && file.saveError == nil && isLink(movedLink), "restoring a target allows retry without losing the link")
        try check(try String(contentsOf: replacementTarget, encoding: .utf8) == "unsaved dangling edit", "retry saves the retained edits")

        let cyclic = try link("cyclic.txt", to: "target.txt")
        let cyclicFile = try await loaded(cyclic)
        try fm.removeItem(at: cyclic)
        try fm.createSymbolicLink(atPath: cyclic.path, withDestinationPath: "cyclic.txt")
        editAndSave(cyclicFile, text: "cycle edit")
        try check(isLink(cyclic) && cyclicFile.isDirty && cyclicFile.saveError != nil, "cyclic links fail without replacing the link or clearing edits")

        let missingParentLink = try link("missing-parent", to: "real-directory")
        let missingParentFile = try await loaded(missingParentLink.appendingPathComponent("child.txt"))
        try fm.removeItem(at: realDirectory)
        editAndSave(missingParentFile, text: "missing parent edit")
        try check(isLink(missingParentLink) && missingParentFile.isDirty && missingParentFile.saveError != nil, "a dangling parent directory reports a save failure")

        let regular = try write("regular.txt")
        let regularFile = try await loaded(regular)
        editAndSave(regularFile, text: "regular edit")
        try check(!isLink(regular) && !regularFile.isDirty && (try String(contentsOf: regular, encoding: .utf8)) == "regular edit", "regular file saves retain existing behavior")
        try fm.removeItem(at: regular)
        editAndSave(regularFile, text: "recreated regular edit")
        try check(!regularFile.isDirty && (try String(contentsOf: regular, encoding: .utf8)) == "recreated regular edit", "saving a removed regular file retains the existing recreate behavior")

        settings.protectEditorSaves = true
        let conflictPath = try write("conflict.txt", "baseline\r\n中文 😀\r\n")
        let conflictFile = try await loaded(conflictPath)
        let originalBaseline = conflictFile.saveBaseline!
        conflictFile.text = "my draft\r\n中文 😀\r\n"
        conflictFile.refreshDirtyState()
        try "agent edit\r\n".write(to: conflictPath, atomically: true, encoding: .utf8)
        try check(!PaneContent.file(conflictFile).save(), "shortcut save refuses an external change without a decision")
        try check(conflictFile.isDirty && conflictFile.text.hasPrefix("my draft") && conflictFile.saveError != nil,
                  "a cancelled save retains the dirty draft and reports the conflict")
        try check(try String(contentsOf: conflictPath, encoding: .utf8) == "agent edit\r\n", "conflict leaves the agent's bytes untouched")
        var conflicts = 0
        let kept = conflictFile.save { conflict, draft in
            conflicts += 1
            precondition(conflict.current.text == "agent edit\r\n" && draft == conflictFile.text)
            return .keepDraft
        }
        try check(!kept && conflicts == 1 && conflictFile.isDirty, "explicit Keep Draft returns a failed save without discarding edits")
        try check(conflictFile.save { _, _ in .overwrite }, "explicit overwrite saves the compared version")
        try check(!conflictFile.isDirty && conflictFile.saveError == nil
                  && (try String(contentsOf: conflictPath, encoding: .utf8)) == conflictFile.text,
                  "overwrite clears dirty state only after writing the draft")

        let sameBytes = try write("same-bytes.txt", "unchanged")
        let sameFile = try await loaded(sameBytes)
        sameFile.text = "draft"
        sameFile.refreshDirtyState()
        let replacement = try write("replacement-same.txt", "unchanged")
        try fm.removeItem(at: sameBytes)
        try fm.moveItem(at: replacement, to: sameBytes)
        conflicts = 0
        _ = sameFile.save { _, _ in conflicts += 1; return .keepDraft }
        try check(conflicts == 1 && sameFile.isDirty, "replacement by identical bytes still detects the changed file identity")
        try fm.removeItem(at: sameBytes)
        _ = sameFile.save { conflict, _ in
            precondition(conflict.current.isMissing)
            return .keepDraft
        }
        try check(!fm.fileExists(atPath: sameBytes.path) && sameFile.isDirty, "deleted files are not silently recreated")
        try check(sameFile.save { _, _ in .overwrite }, "explicit overwrite can recreate a deleted regular file")

        let touchPath = try write("touch.txt", "before")
        let touchFile = try await loaded(touchPath)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: touchPath.path)
        touchFile.text = "after"
        touchFile.refreshDirtyState()
        try check(touchFile.save { _, _ in fatalError("Unchanged bytes must not conflict") },
                  "metadata-only updates do not block unchanged file content")

        let freshPath = try write("same-content-refresh.txt", "before")
        let freshFile = try await loaded(freshPath)
        let oldIdentity = freshFile.saveBaseline!.identity
        try "before".write(to: freshPath, atomically: true, encoding: .utf8)
        freshFile.reloadFromDiskIfClean()
        for _ in 0..<200 where freshFile.saveBaseline?.identity == oldIdentity {
            try await Task.sleep(for: .milliseconds(10))
        }
        freshFile.text = "after refresh"
        freshFile.refreshDirtyState()
        try check(freshFile.save { _, _ in fatalError("A clean reload must refresh the identity baseline") },
                  "clean reload updates the baseline when decoded text stays identical")

        let bomPath = root.appendingPathComponent("bom.txt")
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data("first\r\n中文 😀\r\n".utf8)).write(to: bomPath)
        let bomFile = try await loaded(bomPath)
        bomFile.text = "second\r\n中文 😀\r\n"
        bomFile.refreshDirtyState()
        try check(bomFile.save(), "UTF-8 with BOM can be edited and saved")
        try check(try Data(contentsOf: bomPath) == bom + Data(bomFile.text.utf8), "saving preserves UTF-8 BOM, CRLF and Unicode")

        let linkedTarget = try write("protected-target.txt", "first")
        let linkedReplacement = try write("protected-replacement.txt", "first")
        let protectedLink = try link("protected-link.txt", to: linkedTarget.lastPathComponent)
        let linkedFile = try await loaded(protectedLink)
        linkedFile.text = "draft"
        linkedFile.refreshDirtyState()
        try fm.removeItem(at: protectedLink)
        try fm.createSymbolicLink(atPath: protectedLink.path, withDestinationPath: linkedReplacement.lastPathComponent)
        conflicts = 0
        _ = linkedFile.save { _, _ in conflicts += 1; return .keepDraft }
        try check(conflicts == 1 && (try String(contentsOf: linkedReplacement, encoding: .utf8)) == "first",
                  "retargeted symlinks ask before writing even when contents are identical")
        try check(linkedFile.save { _, _ in .overwrite }, "explicit overwrite follows the current approved symlink target")
        try check(isLink(protectedLink) && (try String(contentsOf: linkedTarget, encoding: .utf8)) == "first"
                  && (try String(contentsOf: linkedReplacement, encoding: .utf8)) == "draft",
                  "overwrite preserves the symlink and writes only its approved target")
        linkedFile.text = "another draft"
        linkedFile.refreshDirtyState()
        try "agent again".write(to: linkedReplacement, atomically: true, encoding: .utf8)
        conflicts = 0
        _ = linkedFile.save { _, _ in
            conflicts += 1
            if conflicts == 1 {
                try! fm.removeItem(at: protectedLink)
                try! fm.createSymbolicLink(atPath: protectedLink.path, withDestinationPath: linkedTarget.lastPathComponent)
                return .overwrite
            }
            return .keepDraft
        }
        try check(conflicts == 2 && linkedFile.isDirty
                  && (try String(contentsOf: linkedTarget, encoding: .utf8)) == "first",
                  "retargeting while the user decides requires a new overwrite approval")

        let racingPath = try write("racing.txt")
        let racingFile = try await loaded(racingPath)
        racingFile.text = "draft"
        racingFile.refreshDirtyState()
        try "agent first".write(to: racingPath, atomically: true, encoding: .utf8)
        conflicts = 0
        _ = racingFile.save { _, _ in
            conflicts += 1
            if conflicts == 1 {
                try! "agent second".write(to: racingPath, atomically: true, encoding: .utf8)
                return .overwrite
            }
            return .keepDraft
        }
        try check(conflicts == 2 && (try String(contentsOf: racingPath, encoding: .utf8)) == "agent second"
                  && racingFile.isDirty, "new agent changes after overwrite approval prompt again")

        let reloadPath = try write("reload.txt")
        let reloadFile = try await loaded(reloadPath)
        reloadFile.text = "draft to discard"
        reloadFile.refreshDirtyState()
        try "loaded agent edit".write(to: reloadPath, atomically: true, encoding: .utf8)
        try check(!reloadFile.save { _, _ in .reload }, "reload keeps a close-before-save operation open")
        for _ in 0..<200 where reloadFile.text != "loaded agent edit" {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(!reloadFile.isDirty && reloadFile.text == "loaded agent edit" && reloadFile.saveError == nil,
                  "explicit reload installs the disk version and clears the error")

        let reloadFailPath = try write("reload-fail.txt")
        let reloadFailFile = try await loaded(reloadFailPath)
        reloadFailFile.text = "keep failed reload draft"
        reloadFailFile.refreshDirtyState()
        try "outside before reload".write(to: reloadFailPath, atomically: true, encoding: .utf8)
        _ = reloadFailFile.save { _, _ in
            try! fm.removeItem(at: reloadFailPath)
            return .reload
        }
        for _ in 0..<200 where reloadFailFile.saveError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(reloadFailFile.isDirty && reloadFailFile.text == "keep failed reload draft"
                  && reloadFailFile.saveError != nil, "a failed reload retains the original dirty file draft")

        let mutationPath = try write("in-place.txt", "baseline")
        let mutationFile = try await loaded(mutationPath)
        mutationFile.text = "my mutation draft"
        mutationFile.refreshDirtyState()
        let mutate = try FileHandle(forWritingTo: mutationPath)
        try mutate.write(contentsOf: Data("external".utf8))
        try mutate.truncate(atOffset: 8)
        try mutate.close()
        conflicts = 0
        _ = mutationFile.save { _, _ in conflicts += 1; return .keepDraft }
        try check(conflicts == 1 && mutationFile.isDirty
                  && (try String(contentsOf: mutationPath, encoding: .utf8)) == "external",
                  "in-place mutation with the same inode and byte count detects changed bytes")

        let permissionDirectory = root.appendingPathComponent("permission")
        try fm.createDirectory(at: permissionDirectory, withIntermediateDirectories: false)
        let permissionPath = permissionDirectory.appendingPathComponent("file.txt")
        try "before".write(to: permissionPath, atomically: true, encoding: .utf8)
        let permissionFile = try await loaded(permissionPath)
        permissionFile.text = "permission draft"
        permissionFile.refreshDirtyState()
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: permissionDirectory.path)
        let permissionSave = permissionFile.save()
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: permissionDirectory.path)
        try check(!permissionSave && permissionFile.isDirty && permissionFile.saveError != nil
                  && permissionFile.text == "permission draft", "atomic write permission errors preserve the draft")
        try check(permissionFile.save() && !permissionFile.isDirty && permissionFile.saveError == nil,
                  "retry after restoring permissions saves and clears the prior error")

        let fifoPath = try write("fifo.txt")
        let fifoFile = try await loaded(fifoPath)
        fifoFile.text = "fifo draft"
        fifoFile.refreshDirtyState()
        try fm.removeItem(at: fifoPath)
        guard mkfifo(fifoPath.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        conflicts = 0
        _ = fifoFile.save { conflict, _ in
            conflicts += 1
            precondition(!conflict.current.canWrite)
            return .keepDraft
        }
        try check(conflicts == 1 && fifoFile.isDirty, "replacement FIFO is rejected without a blocking read")

        let recovered = FileTab(path: conflictPath.path)
        let roundTrip = try JSONDecoder().decode(FileSaveSnapshot.self, from: JSONEncoder().encode(originalBaseline))
        recovered.restoreDraft("recovered draft", baseline: roundTrip)
        conflicts = 0
        _ = recovered.save { _, _ in conflicts += 1; return .keepDraft }
        try check(conflicts == 1 && recovered.text == "recovered draft" && recovered.isDirty,
                  "restored drafts retain their original baseline and detect changes across relaunch")

        settings.protectEditorSaves = false
        try check(PaneContent.file(recovered).save()
                  && (try String(contentsOf: conflictPath, encoding: .utf8)) == "recovered draft",
                  "disabling protection bypasses conflicts in the shared shortcut/close save entry")
        settings.protectEditorSaves = true

        let noOpPath = try write("no-op.txt")
        let noOpFile = try await loaded(noOpPath)
        try "outside".write(to: noOpPath, atomically: true, encoding: .utf8)
        try check(noOpFile.save { _, _ in fatalError("Clean save cannot prompt") }
                  && (try String(contentsOf: noOpPath, encoding: .utf8)) == "outside",
                  "saving a clean editor does not inspect or replace external edits")

        let failPath = try write("fail.txt")
        let failedFile = try await loaded(failPath)
        failedFile.text = "retained failure draft"
        failedFile.refreshDirtyState()
        try fm.removeItem(at: failPath)
        try fm.createDirectory(at: failPath, withIntermediateDirectories: false)
        settings.protectEditorSaves = false
        try check(!failedFile.save() && failedFile.isDirty && failedFile.saveError != nil
                  && failedFile.text == "retained failure draft", "write failures retain text and dirty state")
        settings.protectEditorSaves = true

        let diffPath = try write("diff.txt")
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "--quiet", root.path]
        try git.run()
        git.waitUntilExit()
        let diff = DiffTab(repoRoot: root.path, path: diffPath.lastPathComponent, staged: false, untracked: true, origPath: nil)
        for _ in 0..<200 where diff.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        try check(diff.isEditable && diff.saveBaseline?.text == "before", "editable diff records the worktree baseline from its real load")
        diff.updateEditedContent(fileID: diff.path, contents: "diff draft")
        try "agent diff".write(to: diffPath, atomically: true, encoding: .utf8)
        conflicts = 0
        _ = diff.save { _, draft in
            conflicts += 1
            precondition(draft == "diff draft")
            return .keepDraft
        }
        try check(conflicts == 1 && diff.isDirty && diff.unsavedText == "diff draft"
                  && (try String(contentsOf: diffPath, encoding: .utf8)) == "agent diff",
                  "editable diff conflicts keep both draft and disk content")
        try check(diff.save { _, _ in .overwrite } && !diff.isDirty, "editable diff explicit overwrite saves and clears dirty state")
        diff.updateEditedContent(fileID: diff.path, contents: "disabled diff draft")
        try "external disabled".write(to: diffPath, atomically: true, encoding: .utf8)
        settings.protectEditorSaves = false
        try check(PaneContent.diff(diff).save()
                  && (try String(contentsOf: diffPath, encoding: .utf8)) == "disabled diff draft",
                  "disabled protection bypasses conflicts for editable diffs too")
        settings.protectEditorSaves = true
        diff.updateEditedContent(fileID: diff.path, contents: "reload diff draft")
        try "reloaded diff".write(to: diffPath, atomically: true, encoding: .utf8)
        try check(!diff.save { _, _ in .reload }, "diff reload also keeps a close request open")
        for _ in 0..<200 where diff.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        try check(!diff.isDirty && diff.web.newContent == "reloaded diff" && diff.isEditable && diff.saveError == nil,
                  "diff reload replaces the old draft and restores editability")
        diff.completeEditing(fileID: diff.path, contents: "stale old diff draft")
        try check(!diff.isDirty && diff.web.newContent == "reloaded diff", "late discarded diff editor messages cannot replace the reloaded document")
        diff.updateEditedContent(fileID: diff.web.fileID, contents: "failed diff reload draft")
        try "agent before missing diff".write(to: diffPath, atomically: true, encoding: .utf8)
        _ = diff.save { _, _ in
            try! fm.removeItem(at: diffPath)
            return .reload
        }
        for _ in 0..<200 where diff.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        try check(diff.isDirty && diff.unsavedText == "failed diff reload draft" && diff.saveError != nil,
                  "failed diff reload preserves the dirty draft and reports its error")
    }
}
