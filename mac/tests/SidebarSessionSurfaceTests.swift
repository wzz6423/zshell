import AppKit
import SwiftUI
import Darwin
import ObjectiveC.runtime
@testable import zshell

@MainActor private func pump(_ duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}
@MainActor private func descendants<T: NSView>(_ root: NSView, as type: T.Type) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, as: type) }
}
extension NSApplication {
    @objc(sidebarProbe_activate) fileprivate func sidebarProbe_activate() {}
}
@MainActor private final class PaneCloseAlertResponder {
    private var responses: [NSApplication.ModalResponse]
    private var seen = Set<ObjectIdentifier>()
    private var retainedWindows: [NSWindow] = []
    private var timer: Timer?
    private(set) var prompts = 0
    private(set) var failure: String?
    init(_ responses: [NSApplication.ModalResponse]) {
        self.responses = responses
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.respond() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .modalPanel) }
    }
    private func respond() {
        if let modal = NSApp.modalWindow, seen.insert(ObjectIdentifier(modal)).inserted {
            retainedWindows.append(modal)
            prompts += 1
            if responses.isEmpty { failure = "Unexpected save conflict" }
            NSApp.stopModal(withCode: responses.isEmpty ? .alertFirstButtonReturn : responses.removeFirst())
            return
        }
        for host in NSApp.windows {
            guard let sheet = host.attachedSheet, seen.insert(ObjectIdentifier(sheet)).inserted else { continue }
            retainedWindows.append(sheet)
            prompts += 1
            if responses.isEmpty { failure = "Unexpected close sheet" }
            host.endSheet(sheet, returnCode: responses.isEmpty ? .alertThirdButtonReturn : responses.removeFirst())
        }
    }
    func finish() throws {
        timer?.invalidate(); timer = nil
        guard failure == nil, responses.isEmpty else {
            throw NSError(domain: "pane close responses", code: 4,
                userInfo: [NSLocalizedDescriptionKey: failure ?? "Missing close prompt"])
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}

@main struct SidebarSessionSurfaceTests {
    @MainActor static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        let original = class_getInstanceMethod(NSApplication.self, NSSelectorFromString("activate"))!
        let replacement = class_getInstanceMethod(NSApplication.self, NSSelectorFromString("sidebarProbe_activate"))!
        method_exchangeImplementations(original, replacement)
        let launched = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: app, queue: .main) { _ in
            Task { @MainActor in
                do { try await run(); exit(0) }
                catch { fputs("Pane-close production probe failed: \(error)\n", stderr); exit(1) }
            }
        }
        app.run()
        NotificationCenter.default.removeObserver(launched)
    }
    @MainActor static func run() async throws {
        let backend = CommandLine.arguments[1]
        let settings = AppSettings.shared
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.language = .english
        settings.notifyOnAgentAttention = false
        settings.notifyOnAgentCompletion = false
        settings.terminalStartupProgram = "/bin/sleep 240"
        settings.preserveTerminalSessions = false
        settings.restoreTerminalHistory = false
        settings.resumeAgentConversations = false
        settings.quickTerminalEnabled = false
        settings.sidebarDoubleClickNewSession = true
        let root = FileManager.default.homeDirectoryForCurrentUser
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "pane-fixture"], ["config", "user.name", "Pane Fixture"],
                     ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"],
                     ["config", "core.hooksPath", "/dev/null"], ["commit", "--allow-empty", "-qm", "base"]] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args; process.currentDirectoryURL = repository
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "Git fixture", code: 1) }
        }
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = manager.newProject()
        project.customName = "Pane fixture"
        project.customDirectory = repository.path
        project.sessions.forEach { project.closeContent(.session($0)) }
        let window = NSWindow(contentRect: NSRect(x: -100000, y: -100000, width: 1250, height: 760),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main-pane-close-fixture")
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        manager.attach(to: window)
        QuickTerminalOffscreen.prepare(window)
        window.orderFront(nil)
        var allSessions: [TerminalSession] = []
        var responders: [PaneCloseAlertResponder] = []
        defer {
            responders.forEach { $0.stop() }
            allSessions.forEach { $0.terminate() }
            manager.projects.forEach { $0.terminateAll() }
            manager.windowClosed()
            window.contentView = nil
            window.close()
            _ = try? PTYMuxCommandLine.exchange(method: "terminateAll")
            _ = try? PTYMuxCommandLine.exchange(method: "shutdown")
        }
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: "pane-close", code: 2, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1; print("PASS \(backend): \(label)")
        }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<600 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: "wait", code: 3, userInfo: [NSLocalizedDescriptionKey: label])
        }
        func layout() async throws {
            host.frame = NSRect(x: 0, y: 0, width: 1250, height: 760)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
        }
        func session() async throws -> TerminalSession {
            guard let session = project.newSession(directory: repository.path,
                commandArguments: ["/bin/sleep", "240"], usesConfiguredStartupCommand: false,
                usesConfiguredInitializationCommand: false) else { throw NSError(domain: "session", code: 1) }
            allSessions.append(session)
            try await wait("real PTY starts") { session.shellPid.map { Darwin.kill($0, 0) == 0 } == true }
            return session
        }
        func header(_ title: String) throws -> PaneHeaderNSView {
            guard let header = descendants(host, as: PaneHeaderNSView.self).first(where: {
                descendants($0, as: NSTextField.self).contains { $0.stringValue == title }
            }) else { throw NSError(domain: "pane header \(title)", code: 1) }
            return header
        }
        let first = try await session()
        let tab = project.selectedTab!
        first.title = "FIRST"
        project.splitRight()
        let second = project.selectedSession!
        allSessions.append(second)
        try await wait("second PTY starts") { second.shellPid.map { Darwin.kill($0, 0) == 0 } == true }
        second.title = "SECOND"
        try await layout()
        try check(backend == "ghostty" ? first.surface is ZshellTerminalView : first.surface is AlacrittyTerminalView,
                  "fixture uses requested production terminal backend")
        let firstID = ObjectIdentifier(first.surface), secondID = ObjectIdentifier(second.surface)
        let firstPaneID = tab.paneID(forContent: first.id)!
        let secondPaneID = tab.paneID(forContent: second.id)!
        try check(tab.focusPane(firstPaneID), "existing pane identity can be focused")
        tab.isZoomed = true
        try check(tab.focusPane(firstPaneID) && tab.isZoomed, "reselecting focused pane preserves zoom")
        try check(tab.focusPane(secondPaneID) && !tab.isZoomed, "focusing sibling reveals full layout")
        try check(!tab.focusPane(UUID()), "unknown focus identity does not mutate selection")
        try await layout()
        let firstHeader = try header("FIRST")
        for title in ["FIRST", "SECOND"] {
            let nativeHeader = try header(title)
            nativeHeader.layoutSubtreeIfNeeded()
            let label = descendants(nativeHeader, as: NSTextField.self).first { $0.stringValue == title }!
            let drawing = label.cell!.drawingRect(forBounds: label.bounds)
            let textWidth = (title as NSString).size(withAttributes: [.font: label.font!]).width
            try check(label.frame.width > 100 && drawing.width >= textWidth + 2,
                      "short \(title) header receives available space without truncation")
        }
        try check(firstHeader.closeButton.frame.size == NSSize(width: 24, height: 24)
            && !firstHeader.closeButton.isHidden, "unfocused pane exposes a permanent 24-point native close button")
        try check(firstHeader.closeButton.accessibilityLabel() == AppCommand.closePane.title,
                  "native close button keeps localized Close Pane accessibility label")
        for width: CGFloat in [360, 160, 80, 32, 360] {
            firstHeader.frame.size.width = width; firstHeader.layoutSubtreeIfNeeded()
            try check(!firstHeader.closeButton.isHidden && firstHeader.closeButton.frame.maxX <= width
                && firstHeader.closeButton.frame.size == NSSize(width: 24, height: 24),
                "close stays reachable at pane width \(width)")
        }
        try await layout()
        try check(ObjectIdentifier(first.surface) == firstID && ObjectIdentifier(second.surface) == secondID,
                  "header refresh and focus changes preserve terminal surfaces")
        try header("FIRST").closeButton.performClick(nil)
        try await wait("unfocused pane closes") { !project.sessions.contains { $0.id == first.id } }
        try check(tab.focusedContent?.id == second.id && !second.hasExited
            && second.shellPid.map { Darwin.kill($0, 0) == 0 } == true,
            "closing unfocused pane leaves focused sibling and its job alive")
        project.splitRight()
        let third = project.selectedSession!; allSessions.append(third); third.title = "THIRD"
        try await wait("third PTY starts") { third.shellPid.map { Darwin.kill($0, 0) == 0 } == true }
        tab.isZoomed = true
        try await layout()
        try check(descendants(host, as: PaneHeaderNSView.self).count == 1, "zoom mounts only its pane header")
        try header("THIRD").closeButton.performClick(nil)
        try await wait("zoomed pane closes") { !project.sessions.contains { $0.id == third.id } }
        try check(tab.allPanes.count == 1 && tab.focusedContent?.id == second.id && !tab.isZoomed && !second.hasExited,
                  "zoom close restores surviving pane without ending its shell")
        project.closeFocusedPane()
        try await wait("last terminal closes") { project.tabs.isEmpty }
        try check(manager.projects.contains { $0 === project } && project.selectedTabID == nil,
                  "closing last terminal keeps its empty project")
        try await layout()
        let sidebar = descendants(host, as: ProjectSidebarNSView.self).first!
        let scroll = descendants(sidebar, as: NSScrollView.self).first!
        let document = scroll.documentView!
        sidebar.refresh(); sidebar.layoutSubtreeIfNeeded()
        let rows = descendants(sidebar, as: WorkspaceItemView.self)
        try check(rows.count == 1 && rows[0].titleLabel.stringValue == "Pane fixture",
                  "sidebar renders only the main-based project list")
        func mouse(_ point: NSPoint, _ count: Int) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: document.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
        }
        let blank = NSPoint(x: 20, y: min(document.visibleRect.maxY - 10, document.bounds.maxY - 10))
        document.mouseDown(with: mouse(blank, 1))
        try check(project.tabs.isEmpty, "single blank click creates no session")
        document.mouseDown(with: mouse(blank, 2)); try await layout()
        try check(project.tabs.count == 1, "blank double click creates exactly one session in selected project")
        allSessions += project.sessions
        settings.sidebarDoubleClickNewSession = false
        document.mouseDown(with: mouse(blank, 2)); try await layout()
        try check(project.tabs.count == 1, "disabled gesture creates no session")
        settings.sidebarDoubleClickNewSession = true
        let rowFrame = rows[0].frame
        document.mouseDown(with: mouse(NSPoint(x: rowFrame.midX, y: rowFrame.midY), 2))
        try check(project.tabs.count == 1, "project row double click is excluded from blank gesture")
        guard let menus = rows[0].menuItems?(), case .submenu(_, _, let entries) = menus.last! else {
            throw NSError(domain: "sidebar menu", code: 1)
        }
        try check(entries.contains { if case .action(let title, _, _) = $0 { return title == AppCommand.newSession.title }; return false },
                  "project context menu provides a non-status-bar new-session entry")
        project.closeAll(); try await layout()
        let survivor = try await session(); survivor.title = "SURVIVOR"
        let survivorTab = project.selectedTab!
        func loadedFile(_ name: String) async throws -> FileTab {
            let url = repository.appendingPathComponent(name)
            try "before".write(to: url, atomically: true, encoding: .utf8)
            let file = FileTab(path: url.path)
            try await wait("file load") { if case .text = file.content { return true }; return false }
            file.text = "file draft"; file.refreshDirtyState()
            return file
        }
        let file = try await loadedFile("draft.txt")
        survivorTab.split(Pane(content: .file(file)), toward: .right)
        _ = survivorTab.focusPane(survivorTab.paneID(forContent: survivor.id)!)
        try await layout()
        let fileResponder = PaneCloseAlertResponder([.alertThirdButtonReturn]); responders.append(fileResponder)
        try header(file.name).closeButton.performClick(nil)
        try await wait("file cancel completes") { fileResponder.prompts == 1 && !UnsavedChangesConfirmation.isPending }
        try fileResponder.finish()
        try check(file.isDirty && file.text == "file draft" && survivorTab.allPanes.count == 2
            && survivorTab.focusedContent?.id == survivor.id && !survivor.hasExited,
            "canceling unfocused dirty file close retains draft, focus, pane and running task")
        try "external file".write(to: URL(fileURLWithPath: file.path), atomically: true, encoding: .utf8)
        let fileConflict = PaneCloseAlertResponder([.alertFirstButtonReturn, .alertFirstButtonReturn]); responders.append(fileConflict)
        try header(file.name).closeButton.performClick(nil)
        try await wait("file conflict cancels") { fileConflict.prompts == 2 && !UnsavedChangesConfirmation.isPending }
        try fileConflict.finish()
        try check(file.isDirty && file.text == "file draft" && survivorTab.paneID(forContent: file.id) != nil
            && (try String(contentsOfFile: file.path, encoding: .utf8)) == "external file",
            "Save then Keep Draft preserves dirty file pane and external disk text")
        let fileDiscard = PaneCloseAlertResponder([.alertSecondButtonReturn]); responders.append(fileDiscard)
        try header(file.name).closeButton.performClick(nil)
        try await wait("file discard closes") { survivorTab.paneID(forContent: file.id) == nil }
        try fileDiscard.finish()
        let diffURL = repository.appendingPathComponent("diff.txt")
        try "before".write(to: diffURL, atomically: true, encoding: .utf8)
        let diff = DiffTab(repoRoot: repository.path, path: "diff.txt", staged: false, untracked: true, origPath: nil)
        try await wait("editable Diff loads") { !diff.isLoading }
        try check(diff.isEditable, "probe loads real editable unstaged Diff")
        diff.updateEditedContent(fileID: diff.path, contents: "diff draft")
        survivorTab.split(Pane(content: .diff(diff)), toward: .right)
        survivorTab.isZoomed = true
        try await layout()
        let diffCancel = PaneCloseAlertResponder([.alertThirdButtonReturn]); responders.append(diffCancel)
        try header(diff.title).closeButton.performClick(nil)
        try await wait("Diff cancel completes") { diffCancel.prompts == 1 && !UnsavedChangesConfirmation.isPending }
        try diffCancel.finish()
        try check(diff.unsavedText == "diff draft" && diff.isDirty && survivorTab.isZoomed
            && survivorTab.paneID(forContent: diff.id) != nil && !survivor.hasExited,
            "canceling zoomed editable Diff keeps draft, zoom and terminal task")
        try "external diff".write(to: diffURL, atomically: true, encoding: .utf8)
        let diffConflict = PaneCloseAlertResponder([.alertFirstButtonReturn, .alertFirstButtonReturn]); responders.append(diffConflict)
        try header(diff.title).closeButton.performClick(nil)
        try await wait("Diff conflict cancels") { diffConflict.prompts == 2 && !UnsavedChangesConfirmation.isPending }
        try diffConflict.finish()
        try check(diff.isDirty && diff.unsavedText == "diff draft" && survivorTab.isZoomed
            && (try String(contentsOf: diffURL, encoding: .utf8)) == "external diff",
            "Save then Keep Draft preserves zoomed Diff and external disk text")
        let diffDiscard = PaneCloseAlertResponder([.alertSecondButtonReturn]); responders.append(diffDiscard)
        try header(diff.title).closeButton.performClick(nil)
        try await wait("Diff discard closes") { survivorTab.paneID(forContent: diff.id) == nil }
        try diffDiscard.finish()
        try check(!survivor.hasExited && survivorTab.allPanes.count == 1 && !survivorTab.isZoomed,
                  "closing Diff leaves original terminal alive and clears zoom")
        project.closeAll()
        for kind in ["file", "diff"] {
            let content: PaneContent
            if kind == "file" { content = .file(try await loadedFile("last.txt")) }
            else {
                try "before".write(to: repository.appendingPathComponent("last-diff.txt"), atomically: true, encoding: .utf8)
                let lastDiff = DiffTab(repoRoot: repository.path, path: "last-diff.txt", staged: false, untracked: true, origPath: nil)
                try await wait("last Diff loads") { !lastDiff.isLoading }
                lastDiff.updateEditedContent(fileID: lastDiff.path, contents: "last diff draft")
                content = .diff(lastDiff)
            }
            let lastTab = project.register(PaneTab(content: content)); project.tabs.append(lastTab); project.selectedTabID = lastTab.id
            try await layout()
            let draft = content.unsavedText
            let cancel = PaneCloseAlertResponder([.alertThirdButtonReturn]); responders.append(cancel)
            project.closeFocusedPane()
            try await wait("last \(kind) cancels") { cancel.prompts == 1 && !UnsavedChangesConfirmation.isPending }
            try cancel.finish()
            try check(project.tabs.count == 1 && content.unsavedText == draft && content.isDirty,
                      "canceling last \(kind) close retains tab and draft")
            let save = PaneCloseAlertResponder([.alertFirstButtonReturn]); responders.append(save)
            project.closeFocusedPane()
            try await wait("last \(kind) saves and closes") { project.tabs.isEmpty }
            try save.finish()
            try check(manager.projects.contains { $0 === project }, "saving last \(kind) closes tab but preserves project")
        }
        let worktreeURL = root.appendingPathComponent("worktree")
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["worktree", "add", "-q", "-b", "close-worktree", worktreeURL.path]
        git.currentDirectoryURL = repository; try git.run(); git.waitUntilExit()
        guard git.terminationStatus == 0 else { throw NSError(domain: "worktree", code: 1) }
        let association = try await SessionWorktreeService().association(at: worktreeURL.path, sourceDirectory: repository.path)
        let baseSession = try await session(); baseSession.title = "BASE"
        let worktreeSession = project.newSession(directory: worktreeURL.path, commandArguments: ["/bin/sleep", "240"],
            worktree: association, usesConfiguredStartupCommand: false, usesConfiguredInitializationCommand: false)!
        allSessions.append(worktreeSession); worktreeSession.title = "WORKTREE"
        let worktreeTab = project.selectedTab!
        project.splitRight()
        let worktreeSibling = project.selectedSession!; allSessions.append(worktreeSibling); worktreeSibling.title = "NEIGHBOR"
        try await wait("worktree PTYs start") { [worktreeSession, worktreeSibling].allSatisfy { $0.shellPid.map { Darwin.kill($0, 0) == 0 } == true } }
        try await layout()
        let cancelWorktree = PaneCloseAlertResponder([.alertThirdButtonReturn]); responders.append(cancelWorktree)
        try header("WORKTREE").closeButton.performClick(nil)
        try await wait("worktree cancel completes") { cancelWorktree.prompts == 1 && window.attachedSheet == nil }
        try await Task.sleep(for: .milliseconds(100)); try cancelWorktree.finish()
        try check(worktreeTab.paneID(forContent: worktreeSession.id) != nil && !worktreeSession.hasExited
            && !worktreeSibling.hasExited && FileManager.default.fileExists(atPath: worktreeURL.path),
            "worktree Cancel preserves selected session, neighboring task and checkout")
        let keepWorktree = PaneCloseAlertResponder([.alertFirstButtonReturn]); responders.append(keepWorktree)
        try header("WORKTREE").closeButton.performClick(nil)
        try await wait("worktree keep closes session") { worktreeTab.paneID(forContent: worktreeSession.id) == nil }
        try keepWorktree.finish()
        try check(FileManager.default.fileExists(atPath: worktreeURL.path) && !worktreeSibling.hasExited,
                  "Keep Worktree closes only target pane and preserves checkout")
        manager.projects.forEach { $0.terminateAll() }
        for session in allSessions { _ = await session.waitUntilTerminated() }
        try check(QuickTerminalOffscreen.isSafe(), "production probes stayed offscreen and never activated")
        print("PANE_CLOSE \(backend) \(checks) passed")
    }
}
