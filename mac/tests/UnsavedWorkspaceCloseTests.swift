import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime
@testable import zshell

private struct CloseTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private enum QuitReplyFixture {
    static var replies: [Bool] = []
    static var terminationRequests = 0
    static var delegate: ZshellApplicationDelegate?

    static func install() {
        for (original, replacement) in [
            ("replyToApplicationShouldTerminate:", "unsavedTest_replyToApplicationShouldTerminate:"),
            ("terminate:", "unsavedTest_terminate:"),
        ] {
            let first = class_getInstanceMethod(NSApplication.self, NSSelectorFromString(original))!
            let second = class_getInstanceMethod(NSApplication.self, NSSelectorFromString(replacement))!
            method_exchangeImplementations(first, second)
        }
    }
}

extension NSApplication {
    @objc(unsavedTest_replyToApplicationShouldTerminate:)
    fileprivate func unsavedTest_reply(_ approved: Bool) {
        MainActor.assumeIsolated { QuitReplyFixture.replies.append(approved) }
    }

    @objc(unsavedTest_terminate:)
    fileprivate func unsavedTest_terminate(_ sender: Any?) {
        MainActor.assumeIsolated {
            QuitReplyFixture.terminationRequests += 1
            _ = QuitReplyFixture.delegate?.applicationShouldTerminate(self)
        }
    }
}

@MainActor
private final class AlertResponder {
    private var responses: [NSApplication.ModalResponse]
    private let beforeResponse: (Int, NSWindow) -> Void
    private var seen = Set<ObjectIdentifier>()
    private var sheets: [NSWindow] = []
    private(set) var prompts = 0
    private(set) var failure: String?
    private var timer: Timer?

    init(_ responses: [NSApplication.ModalResponse], beforeResponse: @escaping (Int, NSWindow) -> Void = { _, _ in }) {
        self.responses = responses
        self.beforeResponse = beforeResponse
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.respond() }
        }
    }

    private func respond() {
        for host in NSApp.windows {
            guard let sheet = host.attachedSheet,
                  seen.insert(ObjectIdentifier(sheet)).inserted else { continue }
            sheets.append(sheet)
            prompts += 1
            beforeResponse(prompts, sheet)
            guard !responses.isEmpty else {
                failure = "An unexpected close prompt was presented."
                host.endSheet(sheet, returnCode: .alertThirdButtonReturn)
                continue
            }
            host.endSheet(sheet, returnCode: responses.removeFirst())
        }
    }

    func finish() throws {
        timer?.invalidate()
        timer = nil
        if let failure { throw CloseTestFailure(description: failure) }
        guard responses.isEmpty else { throw CloseTestFailure(description: "An expected close prompt was never presented.") }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

@main
struct UnsavedWorkspaceCloseTests {
    @MainActor private static var checks = 0
    @MainActor private static var controllers: [ZshellWorkspaceWindowController] = []
    @MainActor private static var liveResponders: [AlertResponder] = []
    @MainActor private static var failures: [String] = []

    @MainActor private static func check(_ passed: Bool, _ name: String) throws {
        checks += 1
        print("\(passed ? "PASS" : "FAIL") \(name)")
        guard passed else { throw CloseTestFailure(description: name) }
    }

    @MainActor private static func wait(_ name: String, until condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CloseTestFailure(description: "Timed out: \(name)")
    }

    @MainActor private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    @MainActor private static func responder(
        _ responses: [NSApplication.ModalResponse], beforeResponse: @escaping (Int, NSWindow) -> Void = { _, _ in }
    ) -> AlertResponder {
        let value = AlertResponder(responses, beforeResponse: beforeResponse)
        liveResponders.append(value)
        return value
    }

    @MainActor private static func makeWindow() async throws -> ZshellWorkspaceWindowController {
        let controller = ZshellWorkspaceWindowController(number: controllers.count + 1)
        controllers.append(controller)
        controller.showWindow(nil)
        try await wait("terminal starts") {
            controller.manager.projects.flatMap(\.sessions).first?.shellPid.map { Darwin.kill($0, 0) == 0 } == true
        }
        try await settle()
        return controller
    }

    @MainActor private static func file(_ name: String, root: URL, in project: Project) async throws -> FileTab {
        let path = root.appendingPathComponent(name)
        try "before".write(to: path, atomically: true, encoding: .utf8)
        let value = FileTab(path: path.path)
        try await wait("file loads") { if case .text = value.content { return true }; return false }
        project.tabs.append(PaneTab(content: .file(value)))
        value.text = "edited \(name)"
        value.refreshDirtyState()
        try check(value.isDirty, "the production file buffer becomes dirty")
        return value
    }

    @MainActor private static func diff(_ name: String, root: URL, in project: Project) async throws -> DiffTab {
        try "before".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let value = DiffTab(repoRoot: root.path, path: name, staged: false, untracked: true, origPath: nil)
        project.tabs.append(PaneTab(content: .diff(value)))
        try await wait("diff loads") { !value.isLoading }
        try check(value.isEditable && value.error == nil, "the production unstaged diff is editable")
        value.updateEditedContent(fileID: name, contents: "edited \(name)")
        try check(value.isDirty, "the production Diff buffer becomes dirty")
        return value
    }

    @MainActor private static func isAlive(_ project: Project) -> Bool {
        !project.sessions.isEmpty && project.sessions.allSatisfy { session in
            !session.hasExited && session.shellPid.map { Darwin.kill($0, 0) == 0 } == true
        }
    }

    @MainActor static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        setbuf(stdout, nil)
        QuickTerminalOffscreen.install()
        QuitReplyFixture.install()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Installing the production delegate before AppKit finishes launch
        // would create an extra workspace outside the fixture's controller list.
        let launched = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: app, queue: .main
        ) { _ in
            Task { @MainActor in await run() }
        }
        app.run()
        NotificationCenter.default.removeObserver(launched)
        fputs("FAIL the AppKit event loop stopped before the close probe completed\n", stderr)
        exit(1)
    }

    @MainActor private static func run() async {
        AppLocalization.apply(.english)
        let settings = AppSettings.shared
        settings.terminalBackend = CommandLine.arguments[1] == "alacritty" ? .alacritty : .libghostty
        settings.preserveTerminalSessions = true
        settings.quickTerminalEnabled = false
        settings.applicationPresence = .dockOnly
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let delegate = ZshellApplicationDelegate()
        QuitReplyFixture.delegate = delegate
        NSApp.delegate = delegate
        var status: Int32 = 0
        do {
            try await exerciseProjectAndWindowClose(root: root)
            try await exerciseQuit(root: root, delegate: delegate)
            print("UNSAVED_PHASE_COMPLETE backend=\(CommandLine.arguments[1]) phase=quit")
            try check(QuickTerminalOffscreen.isSafe(), "all regression windows stay offscreen without input capture")
            print("UNSAVED_WORKSPACE_CLOSE_SUCCESS backend=\(CommandLine.arguments[1]) checks=\(checks)")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            status = 1
        }
        liveResponders.forEach { $0.stop() }
        let sessions = controllers.flatMap { $0.manager.projects }.flatMap(\.sessions)
        sessions.forEach { $0.terminate() }
        for session in sessions { _ = await session.waitUntilTerminated() }
        ApplicationPresenceController.shared.stop()
        for controller in controllers { controller.window?.close() }
        _ = try? PTYMuxCommandLine.exchange(method: "terminateAll")
        _ = try? PTYMuxCommandLine.exchange(method: "shutdown")
        exit(status)
    }

    @MainActor private static func exerciseProjectAndWindowClose(root: URL) async throws {
        let controller = try await makeWindow()
        let manager = controller.manager
        let window = controller.window!
        let project = manager.selectedProject!
        let first = try await file("project-save.txt", root: root, in: project)
        let second = try await file("project-cancel.txt", root: root, in: project)
        let initialTabs = project.tabs.map(\.id)
        let cancel = responder([.alertFirstButtonReturn, .alertThirdButtonReturn]) { _, _ in
            if project.tabs.map(\.id) != initialTabs || !isAlive(project) { failures.append("Project teardown ran before confirmation completed.") }
            manager.close(project)
            window.performClose(nil)
        }
        manager.close(project)
        manager.close(project)
        try await wait("project cancel answers") { cancel.prompts == 2 }
        try await settle()
        try cancel.finish()
        try check(failures.isEmpty && manager.projects.contains { $0 === project } && isAlive(project),
                  "Cancel after Save retains the whole project and all live shells; repeated closes do not add sheets")
        try check(project.tabs.map(\.id) == initialTabs && !first.isDirty && second.isDirty,
                  "Save writes successfully while a later Cancel retains every pane and remaining edit")
        try check(try String(contentsOf: URL(fileURLWithPath: first.path), encoding: .utf8) == first.text,
                  "project Save updates the real file")

        let editedDiff = try await diff("project-diff.txt", root: root, in: project)
        let discardThenCancel = responder([.alertSecondButtonReturn, .alertThirdButtonReturn])
        manager.close(project)
        try await wait("project discard cancel answers") { discardThenCancel.prompts == 2 }
        try await settle()
        try discardThenCancel.finish()
        try check(second.isDirty && editedDiff.isDirty && project.tabs.flatMap(\.allContents).contains { $0.id == second.id }
                  && manager.projects.contains { $0 === project } && isAlive(project),
                  "Cancel after Don't Save retains the discarded buffer, Diff and live project")

        let failedPath = root.appendingPathComponent("unavailable-parent/failure.txt")
        second.updatePath(failedPath.path)
        let failed = responder([.alertFirstButtonReturn])
        manager.close(project)
        try await wait("project failed save") { second.saveError != nil }
        try failed.finish()
        try check(second.isDirty && !FileManager.default.fileExists(atPath: failedPath.path) && isAlive(project),
                  "a failed project save preserves the exact file buffer and terminal")
        second.updatePath(root.appendingPathComponent("project-cancel.txt").path)
        let finished = responder([.alertSecondButtonReturn, .alertFirstButtonReturn])
        manager.close(project)
        try await wait("project closes after approval") { !manager.projects.contains { $0 === project } }
        try finished.finish()
        try check(try String(contentsOf: root.appendingPathComponent("project-cancel.txt"), encoding: .utf8) == "before",
                  "Don't Save leaves the original file on disk")
        try check(!editedDiff.isDirty && (try String(contentsOf: root.appendingPathComponent("project-diff.txt"), encoding: .utf8)) == "edited project-diff.txt",
                  "project Save updates the production Diff buffer on disk")

        print("UNSAVED_PHASE_COMPLETE backend=\(CommandLine.arguments[1]) phase=project")
        let worktreeProject = manager.newProject()
        let service = SessionWorktreeService()
        let worktreeFirst = try await service.create(in: root.path, branch: "close-first",
                                                    at: root.deletingLastPathComponent().appendingPathComponent("close-first").path)
        let worktreeSecond = try await service.create(in: root.path, branch: "close-second",
                                                     at: root.deletingLastPathComponent().appendingPathComponent("close-second").path)
        guard let worktreeSessionFirst = worktreeProject.newSession(directory: worktreeFirst.path, worktree: worktreeFirst),
              let worktreeSessionSecond = worktreeProject.newSession(directory: worktreeSecond.path, worktree: worktreeSecond) else {
            throw CloseTestFailure(description: "Worktree sessions did not start.")
        }
        let firstStarted = await worktreeSessionFirst.waitUntilStarted()
        let secondStarted = await worktreeSessionSecond.waitUntilStarted()
        try check(firstStarted && secondStarted, "two production worktree sessions start before project closure")
        let worktreeCancelled = responder([.alertFirstButtonReturn, .alertThirdButtonReturn]) { _, _ in
            if !isAlive(worktreeProject) { failures.append("A worktree session ended before all close choices were answered.") }
        }
        manager.close(worktreeProject)
        try await wait("worktree close cancelled") { worktreeCancelled.prompts == 2 }
        try await settle()
        try worktreeCancelled.finish()
        try check(isAlive(worktreeProject) && manager.projects.contains { $0 === worktreeProject } && failures.isEmpty,
                  "Cancel after Keep Worktree retains every project shell until all choices are approved")
        let kept = responder([.alertFirstButtonReturn, .alertFirstButtonReturn])
        manager.close(worktreeProject)
        try await wait("worktree project closes") { !manager.projects.contains { $0 === worktreeProject } }
        try kept.finish()
        for session in worktreeProject.sessions { _ = await session.waitUntilTerminated() }
        try check(FileManager.default.fileExists(atPath: worktreeFirst.path)
                  && FileManager.default.fileExists(atPath: worktreeSecond.path), "approved Keep Worktree closes sessions without deleting their checkouts")
        try await service.remove(worktreeFirst, requireMerged: false)
        try await service.remove(worktreeSecond, requireMerged: false)

        print("UNSAVED_PHASE_COMPLETE backend=\(CommandLine.arguments[1]) phase=worktree")
        let windowProject = manager.newProject()
        let single = try await file("single-pane.txt", root: root, in: windowProject)
        let singleSaved = responder([.alertFirstButtonReturn])
        windowProject.closeContent(.file(single))
        try await wait("single pane closes after save") { !windowProject.tabs.flatMap(\.allContents).contains { $0.id == single.id } }
        try singleSaved.finish()
        try check(!single.isDirty && isAlive(windowProject), "single-pane Save still closes only the selected file")
        let windowFile = try await file("window-file.txt", root: root, in: windowProject)
        let otherProject = manager.newProject()
        let windowDiff = try await diff("window-diff.txt", root: root, in: otherProject)
        let windowCancel = responder([.alertSecondButtonReturn, .alertThirdButtonReturn])
        print("WINDOW_CLOSE_REQUEST dirty=\(manager.hasUnsavedChanges) delegate=\(String(describing: window.delegate))")
        window.performClose(nil)
        print("WINDOW_CLOSE_DEFERRED visible=\(window.isVisible) registered=\(TerminalManager.automationManagers.contains { $0 === manager })")
        window.performClose(nil)
        try await wait("window cancel answers") { windowCancel.prompts == 2 }
        try await settle()
        try windowCancel.finish()
        try check(window.isVisible && TerminalManager.automationManagers.contains { $0 === manager }
                  && isAlive(windowProject) && isAlive(otherProject) && windowFile.isDirty && windowDiff.isDirty,
                  "window Cancel retains dirty buffers and shells in every project")
        let directory = root.appendingPathComponent("window-diff.txt")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let windowFailed = responder([.alertSecondButtonReturn, .alertFirstButtonReturn])
        window.performClose(nil)
        try await wait("window Diff save fails") { windowDiff.saveError != nil }
        try await settle()
        try windowFailed.finish()
        try check(window.isVisible && windowDiff.isDirty && isAlive(otherProject),
                  "a failed Diff save cancels the window close and retains live sessions")
        try FileManager.default.removeItem(at: directory)
        try "before".write(to: directory, atomically: true, encoding: .utf8)
        let windowSaved = responder([.alertFirstButtonReturn, .alertSecondButtonReturn])
        window.performClose(nil)
        try await wait("window closes after approval") { !TerminalManager.automationManagers.contains { $0 === manager } }
        try windowSaved.finish()
        try check(!window.isVisible && !windowFile.isDirty && windowDiff.isDirty,
                  "window Save and Don't Save close the approved workspace")
        try check(try String(contentsOf: directory, encoding: .utf8) == "before", "window Don't Save retains the disk baseline")
        print("UNSAVED_PHASE_COMPLETE backend=\(CommandLine.arguments[1]) phase=window")
    }

    @MainActor private static func exerciseQuit(root: URL, delegate: ZshellApplicationDelegate) async throws {
        let firstController = try await makeWindow()
        let firstProject = firstController.manager.selectedProject!
        let firstWindow = firstController.window!
        let firstFile = try await file("quit-first.txt", root: root, in: firstProject)
        try await wait("exactly one live workspace before menu-bar quit") {
            TerminalManager.automationManagers.count == 1 && TerminalManager.automationManagers.first === firstController.manager
        }
        AppSettings.shared.applicationPresence = .menuBarOnly
        try await wait("menu-bar policy applied") { AppSettings.shared.applicationPresence == .menuBarOnly }
        NSApp.setActivationPolicy(.prohibited)
        firstWindow.performClose(nil)
        print("MENU_BAR_HIDE visible=\(firstWindow.isVisible) dirty=\(firstFile.isDirty) alive=\(isAlive(firstProject)) presence=\(AppSettings.shared.applicationPresence.rawValue) windows=\(NSApp.windows.compactMap { $0.identifier?.rawValue }) managers=\(TerminalManager.automationManagers.count) delegate=\(String(describing: firstWindow.delegate))")
        try check(!firstWindow.isVisible && firstFile.isDirty && isAlive(firstProject)
                  && firstWindow.attachedSheet == nil, "the menu-bar last window hides with no save prompt and retains edits")
        let hiddenQuit = responder([.alertThirdButtonReturn]) { _, _ in
            if !firstWindow.isVisible { failures.append("Hidden dirty window was not restored for quit.") }
        }
        let beforeHidden = QuitReplyFixture.replies.count
        try check(delegate.applicationShouldTerminate(NSApp) == .terminateLater, "quit waits for asynchronous save confirmation")
        try await wait("hidden quit cancelled") { QuitReplyFixture.replies.count > beforeHidden }
        try hiddenQuit.finish()
        try check(QuitReplyFixture.replies.last == false && firstFile.isDirty && isAlive(firstProject) && failures.isEmpty,
                  "quitting a hidden menu-bar workspace reveals it and Cancel preserves the session")
        firstWindow.performClose(nil)
        try check(!firstWindow.isVisible, "a cancelled quit keeps the menu-bar hide policy")

        let secondController = try await makeWindow()
        let secondProject = secondController.manager.selectedProject!
        let secondWindow = secondController.window!
        let secondDiff = try await diff("quit-second.txt", root: root, in: secondProject)
        secondWindow.miniaturize(nil)
        try await settle()
        try check(secondWindow.isMiniaturized, "the second dirty quit window is minimized")
        let beforeMulti = QuitReplyFixture.replies.count
        let multiCancel = responder([.alertSecondButtonReturn, .alertThirdButtonReturn]) { index, _ in
            if index == 2 && secondWindow.isMiniaturized { failures.append("Minimized dirty window was not restored for quit.") }
        }
        _ = delegate.applicationShouldTerminate(NSApp)
        _ = delegate.applicationShouldTerminate(NSApp)
        try await wait("multiple-window quit cancelled") { QuitReplyFixture.replies.count > beforeMulti }
        try multiCancel.finish()
        try check(QuitReplyFixture.replies.count == beforeMulti + 1 && QuitReplyFixture.replies.last == false
                  && firstFile.isDirty && secondDiff.isDirty && isAlive(firstProject) && isAlive(secondProject) && failures.isEmpty,
                  "multi-window Quit Cancel retains all dirty buffers and shells and coalesces repeated quit requests")

        let failedPath = root.appendingPathComponent("quit-missing-parent/file.txt")
        firstFile.updatePath(failedPath.path)
        let quitFailed = responder([.alertFirstButtonReturn])
        let beforeFailed = QuitReplyFixture.replies.count
        _ = delegate.applicationShouldTerminate(NSApp)
        try await wait("quit save fails") { QuitReplyFixture.replies.count > beforeFailed }
        try quitFailed.finish()
        try check(QuitReplyFixture.replies.last == false && firstFile.saveError != nil && firstFile.isDirty
                  && isAlive(firstProject) && isAlive(secondProject), "save failure rejects quit before cleaning up any sessions")
        firstFile.updatePath(root.appendingPathComponent("quit-first.txt").path)

        let beforeEdit = QuitReplyFixture.replies.count
        let reedited = responder([.alertSecondButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn]) { index, _ in
            if index == 2 { firstFile.text = "edited again during another window's prompt"; firstFile.refreshDirtyState() }
        }
        _ = delegate.applicationShouldTerminate(NSApp)
        try await wait("new edit prompts again") { QuitReplyFixture.replies.count > beforeEdit }
        try reedited.finish()
        try check(reedited.prompts == 3 && QuitReplyFixture.replies.last == false && firstFile.isDirty && isAlive(firstProject),
                  "a discard approval never covers a newer edit made during another window's prompt")

        let beforeEndAll = QuitReplyFixture.replies.count
        let endAllCancelled = responder([.alertThirdButtonReturn])
        delegate.perform(NSSelectorFromString("quitAndEndAllSessions"))
        try await wait("End All quit cancelled") { QuitReplyFixture.replies.count > beforeEndAll }
        try endAllCancelled.finish()
        try check(QuitReplyFixture.terminationRequests == 1 && QuitReplyFixture.replies.last == false
                  && isAlive(firstProject) && isAlive(secondProject), "Quit and End All Sessions also waits before terminating any shell")
        let firstPID = firstProject.sessions.first!.shellPid!
        let secondPID = secondProject.sessions.first!.shellPid!
        let approved = responder([.alertFirstButtonReturn, .alertFirstButtonReturn])
        let beforeApproved = QuitReplyFixture.replies.count
        _ = delegate.applicationShouldTerminate(NSApp)
        try await wait("normal quit approved") { QuitReplyFixture.replies.count > beforeApproved }
        try approved.finish()
        try check(QuitReplyFixture.replies.last == true && !firstFile.isDirty && !secondDiff.isDirty,
                  "Quit Save writes file and Diff buffers before approving termination")
        try check(Darwin.kill(firstPID, 0) == 0 && Darwin.kill(secondPID, 0) == 0,
                  "cancelled End All does not leak into the next normal quit with preserved sessions")
    }
}
