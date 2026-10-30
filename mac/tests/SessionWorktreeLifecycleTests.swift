import AppKit
import Darwin
import Foundation
@testable import zshell

@main
struct SessionWorktreeLifecycleTests {
    @MainActor private static var checks = 0

    @MainActor private static func check(_ passed: Bool, _ name: String) throws {
        checks += 1
        print("\(passed ? "PASS" : "FAIL") \(name)")
        if !passed { throw SessionWorktreeError(message: name) }
    }

    @MainActor private static func rejects(_ name: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch { try check(true, name); return }
        try check(false, name)
    }

    @MainActor private static func shellDirectory(_ session: TerminalSession, marker: URL) async throws -> String {
        session.sendCommand("pwd -P > " + TerminalSession.shellQuote(marker.path))
        session.sendEnter()
        for _ in 0..<50 {
            if let value = try? String(contentsOf: marker, encoding: .utf8), !value.isEmpty {
                return value.trimmingCharacters(in: .newlines)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SessionWorktreeError(message: "The real shell did not write its working directory.")
    }

    @MainActor private static func startForegroundJob(_ session: TerminalSession) async throws -> pid_t {
        session.sendCommand("trap '' HUP; sleep 30")
        session.sendEnter()
        for _ in 0..<50 {
            if let pid = session.surface.foregroundPid, pid != session.shellPid, Darwin.kill(pid, 0) == 0 { return pid }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SessionWorktreeError(message: "The foreground job did not start.")
    }

    @MainActor private static func checkQuickTerminalProtection(
        manager: TerminalManager, project: Project, repo: URL, root: URL
    ) async throws {
        let worktree = try await SessionWorktreeService().create(in: repo.path, branch: "quick-protection")
        let overlay = GlobalTerminalOverlay.shared
        AppSettings.shared.quickTerminalEnabled = true
        AppSettings.shared.quickTerminalMode = .reuse
        overlay.start()
        overlay.toggle()
        guard let reusable = overlay.workspace, let quick = reusable.sessions.first else {
            throw SessionWorktreeError(message: "The reusable Quick Terminal did not start.")
        }
        try check(await quick.waitUntilStarted(), "the real Quick Terminal shell starts with the requested backend")
        quick.sendCommand("cd " + TerminalSession.shellQuote(worktree.path))
        quick.sendEnter()
        let path = try await shellDirectory(quick, marker: root.appendingPathComponent("quick-directory.txt"))
        try check(SessionWorktreeService.canonical(path) == worktree.path, "Quick Terminal enters the linked checkout")
        for _ in 0..<50 where SessionWorktreeService.canonical(quick.currentDirectoryPath) != worktree.path {
            try await Task.sleep(for: .milliseconds(100))
        }
        overlay.toggle()
        try check(overlay.allSessions.filter { $0.id == quick.id }.count == 1,
                  "the hidden reusable workspace contributes one deduplicated session")
        try check(TerminalManager.worktreeIsInUse(worktree.path), "hidden reusable Quick Terminal protects its checkout")
        try check(!TerminalManager.worktreeIsInUse(worktree.path, excluding: quick.id),
                  "excluding the only Quick Terminal user does not keep the checkout busy")
        try await rejects("Git panel cleanup refuses the hidden Quick Terminal checkout") {
            try await TerminalManager.removeWorktreeFromGitPanel(worktree)
        }
        guard let local = project.newSession(directory: worktree.path, worktree: worktree) else {
            throw SessionWorktreeError(message: "The associated local session did not start.")
        }
        try check(await local.waitUntilStarted(), "the associated main-window session starts")
        try await rejects("session cleanup cannot exclude another hidden Quick Terminal user") {
            _ = try await manager.closeWorktreeSession(local, in: project, removeWorktree: true)
        }
        try check(project.sessions.contains { $0 === local } && FileManager.default.fileExists(atPath: worktree.path),
                  "refused Quick Terminal cleanup preserves the checkout and main-window session")
        _ = try await manager.closeWorktreeSession(local, in: project, removeWorktree: false)
        _ = await local.waitUntilTerminated()
        AppSettings.shared.quickTerminalMode = .fresh
        overlay.toggle()
        try check(overlay.workspace !== reusable && overlay.allSessions.contains { $0 === quick },
                  "switching to a fresh workspace retains the hidden reusable session in usage checks")
        try check(TerminalManager.worktreeIsInUse(worktree.path)
                  && !TerminalManager.worktreeIsInUse(worktree.path, excluding: quick.id),
                  "hidden reusable cwd protection and exclusion survive a mode switch")
        try await rejects("Git panel cleanup still refuses after switching Quick Terminal modes") {
            try await TerminalManager.removeWorktreeFromGitPanel(worktree)
        }
        let sessions = overlay.allSessions
        overlay.stop()
        for session in sessions { _ = await session.waitUntilTerminated() }
        try check(!TerminalManager.worktreeIsInUse(worktree.path), "closing Quick Terminal releases its worktree usage")
        try await TerminalManager.removeWorktreeFromGitPanel(worktree)
        try check(!FileManager.default.fileExists(atPath: worktree.path),
                  "Git panel cleanup removes the checkout after all Quick Terminal users stop")
        try check(QuickTerminalOffscreen.isSafe(), "Quick Terminal verification stays offscreen without activating or capturing input")
    }

    @MainActor static func main() async {
        setbuf(stdout, nil)
        QuickTerminalOffscreen.install()
        NSApplication.shared.setActivationPolicy(.prohibited)
        var windows: [UUID: NSWindow] = [:]
        let mounting = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                for session in TerminalManager.automationManagers.flatMap(\.projects).flatMap(\.sessions)
                where windows[session.id] == nil {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                          styleMask: [.titled], backing: .buffered, defer: false)
                    window.contentView = session.surface
                    session.surface.setSurfaceVisible(true)
                    windows[session.id] = window
                }
            }
        }
        var status: Int32 = 0
        do {
            try await run()
            try check(windows.values.allSatisfy { !$0.isVisible }, "all production terminal windows remain hidden")
            print("\(CommandLine.arguments[2]) \(CommandLine.arguments[1]): \(checks) checks, 0 failures")
        } catch {
            fputs("\(error)\n", stderr)
            status = 1
        }
        mounting.invalidate()
        let sessions = TerminalManager.automationManagers.flatMap(\.projects).flatMap(\.sessions)
            + GlobalTerminalOverlay.shared.allSessions
        GlobalTerminalOverlay.shared.stop()
        sessions.forEach { $0.terminate() }
        for session in sessions { _ = await session.waitUntilTerminated() }
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        for window in windows.values { window.contentView = nil }
        exit(status)
    }

    @MainActor private static func run() async throws {
        let phase = CommandLine.arguments[1]
        let backend = TerminalBackend(rawValue: CommandLine.arguments[2])!
        let root = URL(fileURLWithPath: CommandLine.arguments[3])
        let repo = root.appendingPathComponent("repo")
        AppSettings.shared.terminalBackend = backend
        AppSettings.shared.preserveTerminalSessions = false
        let manager = TerminalManager()
        guard let project = manager.selectedProject else { throw SessionWorktreeError(message: "No project was created.") }
        if phase == "restore" {
            let restored = project.sessions.filter { $0.worktree?.branch == "restart" }
            try check(restored.count == 2, "a fresh process restores both associated split panes")
            for (index, session) in restored.enumerated() {
                try check(await session.waitUntilStarted() && session.backend == backend,
                          "restored pane \(index) starts with the requested production backend")
                let path = try await shellDirectory(session, marker: root.appendingPathComponent("restored-\(index).txt"))
                try check(SessionWorktreeService.canonical(path) == session.worktree?.path,
                          "restored pane \(index) runs in its recorded worktree")
            }
            try check(restored[0].worktree == restored[1].worktree, "the persisted split retains one exact worktree identity")
            _ = try await manager.closeWorktreeSession(restored[1], in: project, removeWorktree: false)
            _ = await restored[1].waitUntilTerminated()
            let removed = try await manager.closeWorktreeSession(restored[0], in: project, removeWorktree: true)
            try check(removed && !FileManager.default.fileExists(atPath: restored[0].worktree!.path),
                      "restored association still authorizes safe cleanup of its own checkout")
            return
        }

        project.customDirectory = repo.path
        let first = try await manager.newWorktreeSession(in: project, branch: "lifecycle", sourceDirectory: repo.path)
        try check(first.backend == backend, "new worktree session uses the requested production backend")
        let worktree = first.worktree!
        let path = try await shellDirectory(first, marker: root.appendingPathComponent("created.txt"))
        try check(SessionWorktreeService.canonical(path) == worktree.path,
                  "the real shell starts inside its new worktree (\(path), expected \(worktree.path))")
        project.splitRight()
        guard let split = project.selectedSession, split.id != first.id else {
            throw SessionWorktreeError(message: "The production split did not create another terminal.")
        }
        try check(await split.waitUntilStarted() && split.worktree == worktree, "a production split inherits the exact worktree association")
        try await rejects("cleanup refuses another live session in the worktree") {
            _ = try await manager.closeWorktreeSession(first, in: project, removeWorktree: true)
        }
        try check(project.sessions.contains { $0.id == first.id }, "refused shared cleanup leaves its session open")
        _ = try await manager.closeWorktreeSession(split, in: project, removeWorktree: false)
        _ = await split.waitUntilTerminated()
        let dirty = URL(fileURLWithPath: worktree.path).appendingPathComponent("untracked.txt")
        try Data("user data".utf8).write(to: dirty)
        try await rejects("cleanup refuses untracked data with the real session still open") {
            _ = try await manager.closeWorktreeSession(first, in: project, removeWorktree: true)
        }
        try check(project.sessions.contains { $0.id == first.id } && FileManager.default.fileExists(atPath: dirty.path),
                  "refused dirty cleanup preserves both data and the live session")
        try FileManager.default.removeItem(at: dirty)
        let foregroundPID = try await startForegroundJob(first)
        try check(try await manager.closeWorktreeSession(first, in: project, removeWorktree: true),
                  "clean cleanup stops the real shell and removes its checkout")
        for _ in 0..<20 where Darwin.kill(foregroundPID, 0) == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try check(Darwin.kill(foregroundPID, 0) != 0 && errno == ESRCH,
                  "the captured foreground job is force-stopped when it ignores HUP")
        try check(!FileManager.default.fileExists(atPath: worktree.path), "cleanup removes the checkout directory")

        try await checkQuickTerminalProtection(manager: manager, project: project, repo: repo, root: root)

        let kept = try await manager.newWorktreeSession(in: project, branch: "kept", sourceDirectory: repo.path)
        _ = try await manager.closeWorktreeSession(kept, in: project, removeWorktree: false)
        _ = await kept.waitUntilTerminated()
        manager.reopenClosedSession()
        guard let reopened = project.selectedSession else { throw SessionWorktreeError(message: "Reopen did not create a session.") }
        try check(await reopened.waitUntilStarted() && reopened.worktree == kept.worktree,
                  "reopen keeps the checkout association in its original project")
        _ = try await manager.closeWorktreeSession(reopened, in: project, removeWorktree: false)
        _ = await reopened.waitUntilTerminated()
        manager.close(project)
        manager.reopenClosedSession()
        guard let replacementProject = manager.selectedProject, let replacement = replacementProject.selectedSession else {
            throw SessionWorktreeError(message: "Reopen did not create the replacement project.")
        }
        let replacementStarted = await replacement.waitUntilStarted()
        try check(replacementStarted, "reopen starts a real shell after its original project closes")
        try check(replacement.worktree == kept.worktree,
                  "reopen retains the association after its original project closes")
        _ = try await manager.closeWorktreeSession(replacement, in: replacementProject, removeWorktree: true)

        let restart = try await manager.newWorktreeSession(in: replacementProject, branch: "restart", sourceDirectory: repo.path)
        replacementProject.splitRight()
        guard let restartSplit = replacementProject.selectedSession else { throw SessionWorktreeError(message: "Missing restart split.") }
        try check(await restartSplit.waitUntilStarted() && restartSplit.worktree == restart.worktree,
                  "restart fixture has two live panes associated with one checkout")
        TerminalManager.prepareForApplicationQuit(endAll: true)
        _ = UserDefaults.standard.synchronize()
        try check(!SessionStore.load().isEmpty, "the production quit path writes a restorable workspace snapshot")
    }
}
