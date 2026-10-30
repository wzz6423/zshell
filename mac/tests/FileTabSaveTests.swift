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
    }
}
