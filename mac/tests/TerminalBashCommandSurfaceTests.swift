import AppKit
import Darwin
import Foundation
@testable import zshell

private struct BashSurfaceFailure: Error, CustomStringConvertible { let description: String }

@main
@MainActor
struct TerminalBashCommandSurfaceTests {
    static var checks = 0
    static var backend = ""

    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        do { try run() } catch { fputs("FAIL Bash surface: \(error)\n", stderr); exit(1) }
    }

    static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        TerminalFont.registerBundledFonts()
        backend = CommandLine.arguments[2]
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard home.path.contains("zshell-bash-surface-tests-") else { throw BashSurfaceFailure(description: "disposable HOME required") }
        try "HISTFILE=/dev/null\nPS1='BASH_NATIVE_READY> '\nPS2='BASH_NATIVE_MORE> '\n".write(
            to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        try "HISTFILE=/dev/null\nPROMPT='ZSH_NATIVE_READY> '; RPROMPT=''\n".write(
            to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let settings = AppSettings.shared
        settings.language = .english
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.terminalStartupProgram = "/bin/bash"
        settings.terminalStartupArguments = "-il"
        settings.automaticallyApplyTerminalProfiles = false
        settings.restoreTerminalHistory = false
        settings.preserveTerminalSessions = false
        settings.resumeAgentConversations = false
        settings.commandHistoryEnabled = false
        settings.promptQueueAutoDispatch = false
        settings.notifyOnError = false
        settings.notifyFinishSeconds = 0
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = Project(fallbackName: "Bash fixture", manager: manager, createInitialSession: false)
        project.customDirectory = root.path
        project.launchSettings = .init(environmentVariables: [
            .init(name: "HOME", value: home.path), .init(name: "ZDOTDIR", value: home.path),
            .init(name: "HISTFILE", value: "/dev/null"), .init(name: "BASH_SILENCE_DEPRECATION_WARNING", value: "1"),
        ])
        project.launchSettings.initializationCommand = "export HOME=\(quote(home.path)); export HISTFILE=/dev/null"
        manager.projects.append(project)
        manager.selectedProjectID = project.id
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        var sessions: [TerminalSession] = []
        defer {
            sessions.forEach { $0.terminate() }
            pump(0.7)
            manager.windowClosed()
            window.contentView = nil
            window.close()
        }
        func mount(_ session: TerminalSession) {
            sessions.append(session)
            window.contentView = session.surface
            session.surface.frame = window.contentView!.bounds
            window.orderFront(nil)
            session.surface.setSurfaceVisible(true)
            pump(0.1)
        }
        guard let session = project.newSession(directory: root.path) else { throw BashSurfaceFailure(description: "initial shell missing") }
        mount(session)
        try wait("original Bash reaches a trusted prompt") { session.isCommandTaskShellReady }
        try check(
            session.shellName == "bash" && session.supportsCommandTaskShellIntegration,
            "configured Bash uses the original shell integration")
        try check(!session.terminalPromptQueueIsReady, "Bash leaves the zsh input and queue contracts unchanged")
        try check(QuickTerminalOffscreen.isSafe(), "fixture leaves the user's foreground application unchanged")
        func text(_ target: TerminalSession) -> String { target.surface.readVisibleText(maxLines: 160, maxColumns: 500) ?? "" }
        func run(_ command: String, status: Int) throws {
            try wait("Bash accepts a complete line") { session.isCommandTaskShellReady }
            let task = TerminalCommandTaskStore.shared.submit(
                argv: ["/bin/bash", "-c", command], projectID: project.id,
                paneID: project.tabs[0].allPanes[0].id, session: session)
            try wait("native Bash task reports its own status") {
                TerminalCommandTaskStore.shared.task(id: task.id, projectID: project.id)?.state == .completed
            }
            let result = TerminalCommandTaskStore.shared.task(id: task.id, projectID: project.id)!
            try check(result.exitCode == status, "native Bash task exit status matches the command")
            try check((result.durationNanos ?? 0) > 0, "native task store measures command duration")
            try wait("native Bash task returns to a ready original prompt") { session.isCommandTaskShellReady }
        }
        try run("/usr/bin/true", status: 0)
        try run("/usr/bin/false", status: 1)
        try run("printf 'NATIVE_LINE_ONE\\nNATIVE_LINE_TWO\\n'; false", status: 1)
        try check(text(session).contains("NATIVE_LINE_TWO"), "multiline Bash output reaches the native surface")
        let login = root.appendingPathComponent("login-state")
        session.sendCommand("shopt -q login_shell; printf '%s' \"$?\" > \(quote(login.path))")
        session.sendEnter()
        try wait("original shell publishes its native login state") { FileManager.default.fileExists(atPath: login.path) }
        try wait("native login-state command returns to a prompt") { session.isCommandTaskShellReady }
        try check(try String(contentsOf: login, encoding: .utf8) == "0", "native original Bash remains a login shell")
        let pipeStatus = root.appendingPathComponent("pipe-status")
        session.sendCommand("false | true; printf '%s' \"${PIPESTATUS[*]}\" > \(quote(pipeStatus.path))")
        session.sendEnter()
        try wait("manual pipeline publishes native statuses") { FileManager.default.fileExists(atPath: pipeStatus.path) }
        try check(try String(contentsOf: pipeStatus, encoding: .utf8) == "1 0", "ordinary Bash pipelines preserve PIPESTATUS")
        try wait("manual pipeline returns to the original prompt") { session.isCommandTaskShellReady }
        session.surface.sendText("printf DRAFT_SHOULD_NOT_RUN")
        pump(0.12)
        try check(!session.isCommandTaskShellReady, "programmatic input blocks command task admission")
        session.surface.sendText("\u{15}")
        pump(0.08)
        try check(!session.isCommandTaskShellReady, "erasing a draft stays conservative until a new prompt")
        session.sendEnter()
        try wait("empty line restores Bash task readiness") { session.isCommandTaskShellReady }
        let pasted = session.surface.sendPaste("printf PASTE_DRAFT")
        pump(0.12)
        try check(pasted && !session.isCommandTaskShellReady, "paste input blocks command task admission")
        session.surface.sendText("\u{15}")
        session.sendEnter()
        try wait("paste draft can be cancelled without executing it") { session.isCommandTaskShellReady }
        let busy = TerminalCommandTaskStore.shared.submit(
            argv: ["/bin/sleep", ".35"], projectID: project.id,
            paneID: project.tabs[0].allPanes[0].id, session: session)
        try wait("busy Bash task owns the native foreground") {
            guard let pid = session.surface.foregroundPid, let executable = processExecutablePath(pid: pid) else { return false }
            return (executable as NSString).lastPathComponent == "sleep"
        }
        session.surface.sendText("printf TYPED_AHEAD")
        try wait("busy task completes with typed-ahead input retained") {
            TerminalCommandTaskStore.shared.task(id: busy.id, projectID: project.id)?.state == .completed
        }
        pump(0.15)
        try check(!session.isCommandTaskShellReady, "typed-ahead draft remains unavailable after a busy command completes")
        session.surface.sendText("\u{15}")
        session.sendEnter()
        try wait("typed-ahead cancellation returns to a ready original prompt") { session.isCommandTaskShellReady }
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: 7)!
        session.surface.keyDown(with: event)
        pump(0.12)
        try check(!session.isCommandTaskShellReady, "native keyboard input blocks command task admission")
        session.surface.sendText("\u{15}")
        session.sendEnter()
        try wait("native keyboard draft cancellation returns to a ready prompt") { session.isCommandTaskShellReady }

        guard
            let split = project.automationSplitTerminal(
                beside: project.tabs[0].allPanes[0].id, toward: .right, directory: root.path,
                focus: false, usesConfiguredStartupCommand: false)
        else { throw BashSurfaceFailure(description: "automation split missing") }
        mount(split.session)
        try wait("result split starts the configured original Bash") { split.session.isCommandTaskShellReady }
        try check(split.session.shellName == "bash", "automation result pane preserves simple Bash startup argv")
        let task = TerminalCommandTaskStore.shared.submit(
            argv: ["/bin/sh", "-c", "printf BASH_TASK_OUTPUT; sleep .08; exit 7"], projectID: project.id,
            paneID: split.pane.id, session: split.session)
        try wait("task store retains the command's own native result") {
            TerminalCommandTaskStore.shared.task(id: task.id, projectID: project.id)?.state == .completed
        }
        let result = TerminalCommandTaskStore.shared.task(id: task.id, projectID: project.id)!
        try check(result.exitCode == 7 && (result.durationNanos ?? 0) > 0, "native task result carries status seven and duration")
        try check(result.output?.contains("BASH_TASK_OUTPUT") == true, "native task result captures bounded terminal output")
        let repeated = TerminalCommandTaskStore.shared.task(id: task.id, projectID: project.id)!.json
        try check(result.json == repeated, "native task result stays stable for repeated waits")
        try wait("Bash task returns to a ready prompt") { split.session.isCommandTaskShellReady }
        let interrupted = TerminalCommandTaskStore.shared.submit(
            argv: ["/bin/sleep", "10"], projectID: project.id, paneID: split.pane.id, session: split.session)
        try wait("task enters native foreground sleep") {
            guard let pid = split.session.surface.foregroundPid,
                let path = processExecutablePath(pid: pid)
            else { return false }
            return (path as NSString).lastPathComponent == "sleep"
        }
        if let ghostty = split.session.surface as? ZshellTerminalView {
            ghostty.performBindingAction("text:\\x03")
        } else {
            split.session.surface.sendText("\u{3}")
        }
        do {
            try wait("native Ctrl-C retains the command result") {
                TerminalCommandTaskStore.shared.task(id: interrupted.id, projectID: project.id)?.state == .completed
            }
        } catch {
            print("DIAGNOSTIC interrupted=\(TerminalCommandTaskStore.shared.task(id: interrupted.id, projectID: project.id)!.json)")
            print(
                "DIAGNOSTIC foreground=\(String(describing: split.session.surface.foregroundPid)) root=\(String(describing: split.session.shellPid)) lifecycle=\(split.session.commandLifecycle)"
            )
            print("DIAGNOSTIC text=\(String(reflecting: text(split.session)))")
            if let directory = split.session.commandTaskDirectoryURL {
                print("DIAGNOSTIC task-files=\((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])")
            }
            throw error
        }
        try check(
            TerminalCommandTaskStore.shared.task(id: interrupted.id, projectID: project.id)?.exitCode == 130,
            "native task cancellation reports status 130")
        mount(session)
        session.sendCommand("/bin/bash --noprofile --norc -i")
        session.sendEnter()
        try wait("nested Bash owns a different foreground identity") { session.surface.foregroundPid != session.shellPid }
        try check(!session.isCommandTaskShellReady, "nested Bash is rejected by the original shell task gate")
        session.surface.sendText("exit\r")
        try wait("original Bash regains the foreground after nested shell exit") { session.surface.foregroundPid == session.shellPid }
        pump(0.15)
        session.sendEnter()
        try wait("original Bash regains its prompt after nested shell exit") { session.isCommandTaskShellReady }

        let unsupportedHome = root.appendingPathComponent("unsupported-home", isDirectory: true)
        try FileManager.default.createDirectory(at: unsupportedHome, withIntermediateDirectories: false)
        try "HISTFILE=/dev/null\nPS1='BASH_UNSUPPORTED> '\nPROMPT_COMMAND='true'\n".write(
            to: unsupportedHome.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        // Ghostty's macOS login launcher resets HOME. This private executable
        // restores the fixture HOME before becoming the real /bin/bash.
        let unsupportedBin = root.appendingPathComponent("unsupported-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: unsupportedBin, withIntermediateDirectories: false)
        let unsupportedBash = unsupportedBin.appendingPathComponent("bash")
        try "#!/bin/sh\nexport HOME=\(quote(unsupportedHome.path))\nexec /bin/bash \"$@\"\n".write(
            to: unsupportedBash, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unsupportedBash.path)
        let unsupported = TerminalSession(
            initialDirectory: root.path, commandArguments: [unsupportedBash.path, "-il"],
            launchSettings: project.launchSettings, allowsPersistence: false,
            usesConfiguredStartupCommand: false)
        mount(unsupported)
        let unsupportedIdentity = root.appendingPathComponent("unsupported-identity")
        pump(0.4)
        unsupported.sendCommand("printf '%s' \"$HOME\" > \(quote(unsupportedIdentity.path))")
        unsupported.sendEnter()
        try wait("overwritten prompt hook still opens the real Bash") { FileManager.default.fileExists(atPath: unsupportedIdentity.path) }
        try check(
            try String(contentsOf: unsupportedIdentity, encoding: .utf8) == unsupportedHome.path,
            "native Bash fixture uses its private shell home")
        try check(!unsupported.isCommandTaskShellReady, "overwritten PROMPT_COMMAND safely rejects command results")
        settings.terminalStartupProgram = "/bin/sh"
        settings.terminalStartupArguments = "-c 'sleep 30'"
        try check(!TerminalSession.canLaunchCommandTaskShell, "custom startup programs cannot create result tasks")
        settings.terminalStartupProgram = ""
        settings.terminalStartupArguments = ""
        guard let zsh = project.newSession(directory: root.path) else { throw BashSurfaceFailure(description: "zsh fixture missing") }
        mount(zsh)
        try wait("zsh regression reaches its original ready prompt") { zsh.isCommandTaskShellReady }
        let before = zsh.commandLifecycle.completionSequence
        zsh.sendCommand("false")
        zsh.sendEnter()
        try wait("zsh original completion remains operational") {
            zsh.isCommandTaskShellReady && zsh.commandLifecycle.completionSequence > before
        }
        try check(zsh.commandLifecycle.lastExitCode == 1, "zsh regression retains the actual nonzero result")
        print("BashSurface: \(checks) \(backend) checks passed")
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw BashSurfaceFailure(description: label) }
        checks += 1
        print("PASS \(backend): \(label)")
    }

    static func wait(_ label: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw BashSurfaceFailure(description: "Timed out: " + label) }
            pump(0.01)
        }
    }

    static func pump(_ interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    static func quote(_ value: String) -> String { TerminalSession.shellQuote(value) }
}
