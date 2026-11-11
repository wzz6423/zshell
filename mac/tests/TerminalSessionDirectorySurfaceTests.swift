import AppKit
import Darwin
import Foundation
import UserNotifications
@testable import zshell

@MainActor private final class DirectoryNotificationDelivery: TerminalNotificationDelivery {
    func configure(delegate: any UNUserNotificationCenterDelegate) {}
    func settings(_ completion: @escaping @Sendable (TerminalNotificationAuthorization) -> Void) {
        completion(.init(status: .denied))
    }
    func authorize(_ completion: @escaping @Sendable (Bool) -> Void) { preconditionFailure("No system permission prompts") }
    func deliver(_ record: TerminalNotificationRecord) { preconditionFailure("No system notifications") }
    func remove(ids: [UUID]) {}
}

@main @MainActor
struct TerminalSessionDirectorySurfaceTests {
    static var checks = 0
    static var windows: [UUID: NSWindow] = [:]
    static var sessions: [TerminalSession] = []
    static var markerIndex = 0

    static func pump(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw NSError(domain: "SessionDirectory", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        checks += 1
        print("PASS \(label)")
    }

    static func wait(_ label: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if condition() { return }
            pump(0.025)
        }
        try check(false, label)
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func mount(_ session: TerminalSession) {
        guard windows[session.id] == nil else { return }
        sessions.append(session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        session.surface.frame = window.contentView!.bounds
        window.contentView = session.surface
        session.surface.setSurfaceVisible(true)
        if ProcessInfo.processInfo.environment["ZSHELL_DIRECTORY_TEST_VISIBLE"] != "1" { window.orderFront(nil) }
        windows[session.id] = window
    }

    static func verify(_ session: TerminalSession, directory: String, root: URL, label: String) throws {
        mount(session)
        do {
            try wait(label + " shell starts") {
                session.shellPid != nil && (session.surface.readVisibleText(maxLines: 100, maxColumns: 200) ?? "").contains("DIRECTORY-READY>")
            }
        } catch {
            print("DIRECTORY_DIAGNOSTIC label=\(label) exited=\(session.hasExited) shellPID=\(session.shellPid.map(String.init) ?? "nil") foregroundPID=\(session.surface.foregroundPid.map(String.init) ?? "nil") frame=\(session.surface.frame)")
            print("DIRECTORY_DIAGNOSTIC visible=\(session.surface.readVisibleText(maxLines: 100, maxColumns: 200) ?? "nil")")
            throw error
        }
        markerIndex += 1
        let marker = root.appendingPathComponent("cwd-\(markerIndex).txt")
        session.sendCommand("pwd -P > " + TerminalSession.shellQuote(marker.path))
        session.sendEnter()
        try wait(label + " shell reports cwd") { (try? String(contentsOf: marker, encoding: .utf8))?.isEmpty == false }
        let reported = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines)
        try check(SessionWorktreeService.canonical(reported) == SessionWorktreeService.canonical(directory),
                  label + " real PTY cwd")
        try check(session.shellPid.flatMap(processWorkingDirectory(pid:)).map(SessionWorktreeService.canonical)
                    == SessionWorktreeService.canonical(directory), label + " kernel cwd")
        try check(SessionWorktreeService.canonical(session.currentDirectoryPath) == SessionWorktreeService.canonical(directory),
                  label + " session cwd")
    }

    static func newSession(_ project: Project) throws -> TerminalSession {
        guard let session = project.newSession() else {
            try check(false, "new session is available")
            fatalError()
        }
        return session
    }

    static func git(_ arguments: [String], directory: String) throws {
        let result = GitCommandRunner.runData(arguments, in: directory)
        try check(result.status == 0, "fixture git " + arguments[0])
    }

    static func main() throws {
        if RemoteSessionRelay.shouldRun { RemoteSessionRelay.run() }
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let visible = ProcessInfo.processInfo.environment["ZSHELL_DIRECTORY_TEST_VISIBLE"] == "1"
        if !visible { QuickTerminalOffscreen.install() }
        let backend = TerminalBackend(rawValue: CommandLine.arguments[1])!
        let home = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let root = home.appendingPathComponent("fixtures")
        let results = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        precondition(AppSettings.configURL.path.hasPrefix(home.path))
        TerminalNotificationService.shared = TerminalNotificationService(delivery: DirectoryNotificationDelivery())
        let settings = AppSettings.shared
        settings.terminalBackend = backend
        settings.preserveTerminalSessions = false
        settings.terminalStartupProgram = "/bin/zsh"
        settings.terminalStartupArguments = "-i"
        settings.shellCompletions = false
        settings.notifyOnError = false
        settings.notifyOnAgentAttention = false
        settings.notifyOnAgentCompletion = false
        settings.quickTerminalEnabled = true
        settings.quickTerminalMode = .fresh
        settings.terminalProfiles = []
        AppLocalization.apply(.english)
        let fm = FileManager.default
        let repo = root.appendingPathComponent("repo")
        let current = repo.appendingPathComponent("sub")
        let custom = root.appendingPathComponent("custom space 中")
        let explicit = root.appendingPathComponent("explicit")
        let pinned = root.appendingPathComponent("pinned")
        let grouped = root.appendingPathComponent("group")
        for directory in [repo, current, custom, explicit, pinned, grouped, results] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try git(["init", "-q", "--initial-branch=main"], directory: repo.path)
        try git(["config", "user.name", "Directory Fixture"], directory: repo.path)
        try git(["config", "user.email", "fixture@example.invalid"], directory: repo.path)
        try git(["config", "commit.gpgsign", "false"], directory: repo.path)
        try git(["config", "core.hooksPath", "/dev/null"], directory: repo.path)
        try git(["commit", "--allow-empty", "-qm", "base"], directory: repo.path)
        let manager = TerminalManager()
        let project = manager.selectedProject!
        let managerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        manager.attach(to: managerWindow)
        var settingsWindow: NSWindow?
        defer {
            GlobalTerminalOverlay.shared.stop()
            (sessions + manager.projects.flatMap(\.sessions)).forEach { $0.terminate() }
            pump(0.3)
            for window in windows.values { window.contentView = nil; window.orderOut(nil) }
            settingsWindow?.contentView = nil
            settingsWindow?.orderOut(nil)
            managerWindow.orderOut(nil)
            manager.windowClosed()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        }
        for content in project.tabs.flatMap(\.allContents) {
            project.closeContent(content, confirmWorktree: false, recordClosedSession: false)
        }
        let anchor = project.newSession(directory: current.path)!
        try verify(anchor, directory: current.path, root: root, label: "explicit source")
        let anchorTab = project.selectedTabID
        let originalPID = anchor.shellPid
        settings.newSessionCustomDirectory = custom.path
        for (policy, expected) in [(NewSessionDirectoryPolicy.current, current.path), (.project, repo.path),
                                   (.home, home.path), (.custom, custom.path)] {
            settings.newSessionDirectoryPolicy = policy
            project.selectedTabID = anchorTab
            try verify(newSession(project), directory: expected, root: root, label: policy.rawValue)
            project.selectedTabID = anchorTab
            manager.selectedProjectID = project.id
            let created = manager.newProject()
            try verify(created.selectedSession!, directory: expected, root: root, label: "new project " + policy.rawValue)
        }
        settings.newSessionDirectoryPolicy = .custom
        project.selectedTabID = anchorTab
        manager.selectedProjectID = project.id
        try check(!anchor.hasExited && anchor.shellPid == originalPID, "policy changes preserve existing shell")
        var profile = TerminalProfile(name: "Custom directory profile")
        profile.directory = custom.path
        settings.terminalProfiles = [profile]
        let profiled = try newSession(project)
        try check(profiled.activeTerminalProfileID == profile.id, "initial profile matches resolved directory")
        try verify(profiled, directory: custom.path, root: root, label: "profile custom")
        settings.terminalProfiles = []
        project.selectedTabID = anchorTab
        let explicitSession = project.newSession(directory: explicit.path)!
        try verify(explicitSession, directory: explicit.path, root: root, label: "explicit overrides custom")
        project.customDirectory = pinned.path
        try verify(newSession(project), directory: pinned.path, root: root, label: "pin overrides custom")
        project.customDirectory = nil
        let group = ProjectGroup(name: "Fixture group", kind: .folder(path: grouped.path))
        ProjectGroupStore.shared.add(group)
        project.groupID = group.id
        try verify(newSession(project), directory: grouped.path, root: root, label: "group overrides custom")
        let groupProject = manager.newProject(in: group)
        try verify(groupProject.selectedSession!, directory: grouped.path, root: root, label: "group project overrides custom")
        project.groupID = nil
        ProjectGroupStore.shared.remove(group)
        project.selectedTabID = anchorTab
        project.splitRight()
        let split = project.selectedTab!.sessions.last!
        try verify(split, directory: current.path, root: root, label: "split source overrides custom")
        let targetPaneID = project.selectedTab!.paneID(forContent: anchor.id)!
        let automationSplit = project.automationSplitTerminal(beside: targetPaneID, toward: .bottom,
            directory: nil, focus: false)!.session
        try verify(automationSplit, directory: current.path, root: root, label: "automation split source")
        let tabGroup = project.createTabGroup()
        try verify(project.newSession(inTabGroup: tabGroup.id)!, directory: custom.path, root: root, label: "tab group policy")
        project.selectedTabID = anchorTab
        for invalid in ["relative", root.appendingPathComponent("missing").path] {
            settings.newSessionCustomDirectory = invalid
            try verify(newSession(project), directory: current.path, root: root, label: "invalid custom fallback")
            project.selectedTabID = anchorTab
        }
        let file = root.appendingPathComponent("file.txt")
        try "fixture".write(to: file, atomically: true, encoding: .utf8)
        settings.newSessionCustomDirectory = file.path
        try verify(newSession(project), directory: current.path, root: root, label: "file custom fallback")
        settings.newSessionCustomDirectory = custom.path
        let missingExplicit = project.newSession(directory: root.appendingPathComponent("missing-explicit").path)!
        try verify(missingExplicit, directory: home.path, root: root, label: "missing explicit uses home")
        let template = WorkspaceTemplate(name: "Directory template", tabs: [
            .init(layout: .pane(.init(content: .session(workingDirectory: "sub"), weight: 1)),
                  focusedPaneIndex: 0, terminals: [.init(paneIndex: 0)])
        ], selectedTabIndex: 0)
        let applied = try manager.applyWorkspaceTemplate(template, projectRoot: repo.path)
        try verify(applied.selectedSession!, directory: current.path, root: root, label: "template preserves directory")
        let restored = project.restoreTab(from: .init(
            layout: .pane(.init(content: .session(workingDirectory: explicit.path), weight: 1)), focusedPaneIndex: 0
        ))!.sessions[0]
        try verify(restored, directory: explicit.path, root: root, label: "restored preserves directory")
        manager.openOrFocusDirectories([explicit.path])
        try verify(manager.selectedSession!, directory: explicit.path, root: root, label: "Finder preserves directory")
        TerminalManager.openCLIProject(arguments: [], directory: explicit.path, path: nil)
        try verify(manager.selectedSession!, directory: explicit.path, root: root, label: "CLI preserves directory")
        manager.selectedProjectID = project.id
        project.selectedTabID = anchorTab
        settings.newSessionDirectoryPolicy = .current
        manager.runQuickLaunchEntry(.init(name: "Quick launch context", kind: .command(command: ":", directory: nil)))
        try verify(manager.selectedSession!, directory: current.path, root: root, label: "Quick Launch inherits local context")
        settings.newSessionDirectoryPolicy = .custom
        let worktreePath = root.appendingPathComponent("linked")
        try git(["worktree", "add", "-qb", "fixture-linked", worktreePath.path], directory: repo.path)
        let worktreeNested = worktreePath.appendingPathComponent("nested")
        try fm.createDirectory(at: worktreeNested, withIntermediateDirectories: true)
        manager.selectedProjectID = project.id
        project.selectedTabID = anchorTab
        project.selectedTab?.focusedPaneID = targetPaneID
        settings.newSessionDirectoryPolicy = .project
        anchor.sendCommand("/bin/zsh -c " + TerminalSession.shellQuote("cd -- \"$1\" && exec /bin/sleep 60")
            + " fixture " + TerminalSession.shellQuote(worktreeNested.path))
        anchor.sendEnter()
        try wait("foreground job moves into its linked checkout") {
            anchor.foregroundDirectoryPath.map(SessionWorktreeService.canonical)
                == SessionWorktreeService.canonical(worktreeNested.path)
        }
        let foregroundPID = anchor.surface.foregroundPid!
        try verify(newSession(project), directory: worktreePath.path, root: root, label: "project follows foreground checkout")
        Darwin.kill(foregroundPID, SIGTERM)
        try wait("source shell regains foreground after checkout job") { anchor.surface.foregroundPid == anchor.shellPid }
        try check(SessionWorktreeService.canonical(anchor.currentDirectoryPath) == SessionWorktreeService.canonical(current.path),
                  "foreground checkout keeps source shell directory")
        settings.newSessionDirectoryPolicy = .custom
        var associationResult: Result<SessionWorktree, Error>?
        let associationTask = Task { @MainActor in
            do { associationResult = .success(try await SessionWorktreeService().association(at: worktreePath.path, sourceDirectory: repo.path)) }
            catch { associationResult = .failure(error) }
        }
        defer { associationTask.cancel() }
        try wait("worktree association uses current Git identity") { associationResult != nil }
        let association = try associationResult!.get()
        let worktreeSession = project.newSession(directory: association.path, worktree: association)!
        try verify(worktreeSession, directory: association.path, root: root, label: "worktree overrides custom")
        var removalResult: Error?
        var removalFinished = false
        let removal = Task { @MainActor in
            do { try await TerminalManager.removeWorktreeFromGitPanel(association) }
            catch { removalResult = error }
            removalFinished = true
        }
        defer { removal.cancel() }
        try wait("worktree removal reserves resolved target") {
            TerminalManager.isRemovingWorktree(containing: association.path)
        }
        settings.newSessionCustomDirectory = association.path
        let sessionCount = project.sessions.count
        try check(project.newSession() == nil && project.sessions.count == sessionCount,
                  "resolved custom directory is blocked during worktree removal")
        try wait("worktree removal finishes safely") { removalFinished }
        try check(removalResult != nil && fm.fileExists(atPath: worktreePath.path), "worktree with live source remains on disk")
        settings.newSessionCustomDirectory = custom.path
        let symlink = root.appendingPathComponent("linked-custom")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: custom)
        settings.newSessionCustomDirectory = symlink.path
        try verify(newSession(project), directory: custom.path, root: root, label: "custom symlink enters real target")
        settings.newSessionCustomDirectory = custom.path
        let ssh = Project(fallbackName: "SSH fixture", manager: manager,
            location: .ssh(endpoint: try SSHEndpoint(host: "127.0.0.1", port: 1), remoteDirectory: "/remote/root", authentication: .password),
            createInitialSession: false)
        let sshSession = ssh.newSession()!
        try check(sshSession.currentDirectoryPath == home.path && ssh.remoteDirectory == "/remote/root",
                  "SSH keeps remote root and local relay home")
        sshSession.terminate()
        let host = try RemoteHost(name: "Shared fixture", address: "tailscale://127.0.0.1:1")
        let shared = Project(fallbackName: "Shared fixture", manager: manager,
                             location: .shared(host: host, directory: "/remote/root"), createInitialSession: false)
        let sharedSession = shared.newSession()!
        try check(sharedSession.remoteConnection?.projectDirectory == "/remote/root"
                    && sharedSession.currentDirectoryPath == "/remote/root", "shared root is not replaced by local custom path")
        try check(shared.newSessionDirectoryContext.currentDirectory == nil && ssh.newSessionDirectoryContext.currentDirectory == nil,
                  "remote context cannot feed a new local project")
        sharedSession.terminate()
        manager.selectedProjectID = project.id
        project.selectedTabID = anchorTab
        let overlay = GlobalTerminalOverlay.shared
        overlay.start()
        overlay.toggle()
        let quick = overlay.workspace!.sessions[0]
        try verify(quick, directory: custom.path, root: root, label: "fresh Quick Terminal custom")
        overlay.toggle()
        settings.newSessionDirectoryPolicy = .current
        overlay.toggle()
        try verify(overlay.workspace!.sessions[0], directory: current.path, root: root, label: "fresh Quick Terminal current")
        overlay.toggle()
        settings.quickTerminalMode = .reuse
        settings.newSessionDirectoryPolicy = .custom
        overlay.toggle()
        let reusable = overlay.workspace!.sessions[0]
        try verify(reusable, directory: custom.path, root: root, label: "first reusable Quick Terminal custom")
        overlay.toggle()
        settings.newSessionDirectoryPolicy = .home
        overlay.toggle()
        try check(overlay.workspace!.sessions[0] === reusable && !reusable.hasExited,
                  "reusable Quick Terminal keeps its existing session after policy change")
        overlay.toggle()
        overlay.stop()
        let pane = SettingsTerminalPane()
        pane.setCategory(.terminal)
        let uiWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
                                styleMask: [.titled], backing: .buffered, defer: false)
        uiWindow.isReleasedWhenClosed = false
        uiWindow.contentViewController = pane
        uiWindow.title = "Session Directory Fixture · " + backend.rawValue
        settingsWindow = uiWindow
        settings.newSessionDirectoryPolicy = .custom
        pane.syncFromSettings()
        try check(pane.revealSearchResult(String(localized: "New session directory")), "settings search reveals the directory row")
        let editor = descendants(pane.view).compactMap { $0 as? TerminalSessionDirectorySettingsView }.first!
        let popup = descendants(editor).compactMap { $0 as? NSPopUpButton }.first!
        let field = descendants(editor).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
        popup.selectItem(at: 2)
        NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        try check(settings.newSessionDirectoryPolicy == .home, "AppKit policy selection persists")
        popup.selectItem(at: 3)
        NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        field.stringValue = "relative"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try check(settings.newSessionCustomDirectory == "relative", "AppKit custom directory edits persist")
        try check(descendants(editor).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == String(localized: "Enter an absolute path or ~/folder. New sessions use the current directory until this path is valid.")
        }, "AppKit shows the actual invalid path reason")
        field.stringValue = custom.path
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        pane.view.layoutSubtreeIfNeeded()
        var workspaceController: ZshellWorkspaceWindowController?
        if ProcessInfo.processInfo.environment["ZSHELL_DIRECTORY_TEST_WORKSPACE"] == "1" {
            let controller = ZshellWorkspaceWindowController(number: 1)
            workspaceController = controller
            defer {
                controller.manager.projects.forEach { $0.terminateAll() }
                controller.window?.contentView = nil
                controller.window?.orderOut(nil)
                controller.manager.windowClosed()
            }
            for content in controller.manager.projects.flatMap(\.tabs).flatMap(\.allContents) {
                controller.manager.selectedProject?.closeContent(content, confirmWorktree: false, recordClosedSession: false)
            }
            let previewProject = controller.manager.selectedProject!
            previewProject.customName = "Directory acceptance"
            let previewSession = previewProject.newSession(directory: current.path)!
            let previewTabID = previewProject.selectedTabID
            let explicitPreview = previewProject.newSession(directory: explicit.path, tabTitle: "Explicit directory")!
            try verify(explicitPreview, directory: explicit.path, root: root, label: "workspace explicit directory")
            previewProject.selectedTabID = previewTabID
            let pinnedPreview = controller.manager.newProject()
            pinnedPreview.customName = "Pinned directory"
            pinnedPreview.customDirectory = pinned.path
            let pinnedSession = pinnedPreview.newSession()!
            try verify(pinnedSession, directory: pinned.path, root: root, label: "workspace pinned directory")
            let previewGroup = ProjectGroup(name: "Directory group", kind: .folder(path: grouped.path))
            ProjectGroupStore.shared.add(previewGroup)
            defer { ProjectGroupStore.shared.remove(previewGroup) }
            let groupedPreview = controller.manager.newProject(in: previewGroup)
            groupedPreview.customName = "Group directory"
            try verify(groupedPreview.selectedSession!, directory: grouped.path, root: root, label: "workspace group directory")
            controller.manager.selectedProjectID = previewProject.id
            previewProject.selectedTabID = previewTabID
            previewSession.sendCommand("pwd -P")
            previewSession.sendEnter()
            controller.window?.title = "Session Directory Workspace · " + backend.rawValue
            if visible {
                NSApp.setActivationPolicy(.regular)
                controller.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            print("DIRECTORY_WORKSPACE_READY home=\(home.path) current=\(current.path) custom=\(custom.path) explicit=\(explicit.path) pinned=\(pinned.path) group=\(grouped.path)")
            pump(min(max(Double(ProcessInfo.processInfo.environment["ZSHELL_DIRECTORY_TEST_HOLD_SECONDS"] ?? "10") ?? 10, 0), 120))
        }
        if visible {
            uiWindow.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        pump(0.2)
        if let representation = pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds) {
            pane.view.cacheDisplay(in: pane.view.bounds, to: representation)
            try representation.representation(using: .png, properties: [:])?.write(to: results.appendingPathComponent(backend.rawValue + ".png"))
        }
        if visible {
            let seconds = Double(ProcessInfo.processInfo.environment["ZSHELL_DIRECTORY_TEST_HOLD_SECONDS"] ?? "10") ?? 10
            pump(min(max(seconds, 0), 120))
        } else {
            try check(QuickTerminalOffscreen.isSafe(), "all verification windows stay offscreen without focus capture")
        }
        try check(anchor.shellPid == originalPID && !anchor.hasExited, "all new-session and settings operations retain the source shell")
        withExtendedLifetime(workspaceController) {}
        print("\(backend.rawValue): \(checks) directory surface checks passed")
    }
}
