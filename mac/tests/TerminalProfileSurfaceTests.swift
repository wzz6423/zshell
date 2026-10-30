import AppKit
import Darwin
@testable import zshell

@MainActor
private func pumpProfiles(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@main
struct TerminalProfileSurfaceTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let backend = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        let zshDirectory = root.appendingPathComponent("zsh", isDirectory: true)
        for directory in [firstDirectory, secondDirectory, zshDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try """
        HISTFILE=/dev/null
        unsetopt SHARE_HISTORY INC_APPEND_HISTORY INC_APPEND_HISTORY_TIME APPEND_HISTORY
        PROMPT='PROFILE_READY> '
        RPROMPT=''
        builtin print -r -- ${PROFILE_CASE:-none} > profile-env
        """.write(to: zshDirectory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let settings = AppSettings.shared
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.terminalStartupProgram = ""
        settings.terminalStartupArguments = ""
        settings.preserveTerminalSessions = false
        settings.fontSize = 12
        var base = TerminalProfile(name: "Directory fixture")
        base.host = "localhost"
        base.user = NSUserName()
        base.directory = firstDirectory.path
        base.appearance.fontSize = 24
        base.launchSettings.environmentVariables = [.init(name: "PROFILE_CASE", value: "matched")]
        var foreground = TerminalProfile(name: "Foreground fixture")
        foreground.directory = firstDirectory.path
        foreground.program = "sleep"
        foreground.appearance.fontSize = 28
        let unexpectedCommand = root.appendingPathComponent("unexpected-command")
        foreground.startupProgram = "/usr/bin/touch"
        foreground.startupArguments = unexpectedCommand.path
        settings.terminalProfiles = [foreground, base]

        let environment = ["ZDOTDIR": zshDirectory.path, "LC_ALL": "en_US.UTF-8"]
        let first = TerminalSession(initialDirectory: firstDirectory.path, additionalEnvironment: environment)
        let second = TerminalSession(initialDirectory: secondDirectory.path, additionalEnvironment: environment)
        let sessions = [first, second]
        let windows = sessions.enumerated().map { index, session in
            let window = NSWindow(contentRect: NSRect(x: CGFloat(80 + index * 40), y: CGFloat(80 + index * 40), width: 800, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("main-profile-test-\(index)")
            window.contentView = session.surface
            window.orderFront(nil)
            session.surface.setSurfaceVisible(true)
            return window
        }
        defer {
            sessions.forEach { $0.terminate() }
            pumpProfiles(0.3)
            windows.forEach { $0.contentView = nil; $0.close() }
        }

        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: label, code: 1) }
            print("PASS: \(backend) \(label)")
        }
        func wait(_ label: String, timeout: TimeInterval = 8, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                first.refreshTerminalProfile()
                second.refreshTerminalProfile()
                if condition() { return }
                pumpProfiles(0.03)
            }
            throw NSError(domain: label, code: 1)
        }
        func command(_ session: TerminalSession, _ text: String) {
            session.sendCommand(text)
            session.sendEnter()
        }
        func quote(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        func grid(_ name: String) throws -> [Int] {
            let file = root.appendingPathComponent(name)
            command(first, "stty size > " + quote(file.path))
            try wait("grid \(name)") {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
                return text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }.count == 2
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            return text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        }

        try wait("shell startup") {
            first.shellPid != nil && second.shellPid != nil
                && FileManager.default.fileExists(atPath: firstDirectory.appendingPathComponent("profile-env").path)
                && FileManager.default.fileExists(atPath: secondDirectory.appendingPathComponent("profile-env").path)
        }
        let firstPID = first.shellPid!
        let secondPID = second.shellPid!
        try wait("initial profile") { first.activeTerminalProfileID == base.id }
        try check(second.activeTerminalProfileID == nil, "independent pane has original profile")
        try check(first.surface.profileAppearance.fontSize == 24, "matching pane has profile appearance")
        let firstEnv = try String(contentsOf: firstDirectory.appendingPathComponent("profile-env"), encoding: .utf8)
        let secondEnv = try String(contentsOf: secondDirectory.appendingPathComponent("profile-env"), encoding: .utf8)
        try check(firstEnv.trimmingCharacters(in: .whitespacesAndNewlines) == "matched", "launch environment applies")
        try check(secondEnv.trimmingCharacters(in: .whitespacesAndNewlines) == "none", "launch environment stays pane-local")

        pumpProfiles(1)
        let profileGrid = try grid("profile-grid")
        first.selectTerminalProfile(.original)
        try check(first.activeTerminalProfileID == nil && first.surface.profileAppearance.fontSize == nil, "manual original selection")
        pumpProfiles(1)
        let originalGrid = try grid("original-grid")
        print("GRID: \(backend) profile=\(profileGrid) original=\(originalGrid)")
        try check(profileGrid.count == 2 && originalGrid.count == 2 && originalGrid[1] > profileGrid[1],
                  "font change resizes the real PTY")
        first.selectTerminalProfile(.profile(foreground.id))
        try check(first.activeTerminalProfileID == foreground.id && first.surface.profileAppearance.fontSize == 28,
                  "manual profile selection")
        try check(second.activeTerminalProfileID == nil, "manual selection stays pane-local")
        first.selectTerminalProfile(.automatic)
        try wait("automatic selection") { first.activeTerminalProfileID == base.id }

        command(first, "cd " + quote(secondDirectory.path))
        try wait("directory mismatch restores original") { first.activeTerminalProfileID == nil }
        try check(first.surface.profileAppearance.fontSize == nil, "unmatched profile restores appearance")
        command(first, "cd " + quote(firstDirectory.path))
        try wait("directory match returns") { first.activeTerminalProfileID == base.id }
        command(first, "/bin/sleep 3")
        try wait("foreground program match", timeout: 2) { first.activeTerminalProfileID == foreground.id }
        try wait("foreground program exits", timeout: 6) { first.activeTerminalProfileID == base.id }
        try check(first.shellPid == firstPID && second.shellPid == secondPID && kill(firstPID, 0) == 0,
                  "profile switches keep the shell processes alive")
        try check(!FileManager.default.fileExists(atPath: unexpectedCommand.path),
                  "switching profiles never runs a startup command")
        func opacity(_ session: TerminalSession) -> Double? {
            Mirror(reflecting: session.surface).children.first { $0.label == "backgroundOpacity" }
                .flatMap { ($0.value as? Double) ?? ($0.value as? CGFloat).map(Double.init) }
        }
        first.applyTheme(backgroundOpacity: 0.4)
        first.selectTerminalProfile(.profile(base.id))
        first.selectTerminalProfile(.profile(foreground.id))
        try check(opacity(first).map { abs($0 - 0.4) < 0.001 } == true, "profile switches keep host background opacity")
        first.applyTheme()
        first.selectTerminalProfile(.automatic)
        try wait("automatic selection after opacity") { first.activeTerminalProfileID == foreground.id || first.activeTerminalProfileID == base.id }
        let currentEnvironment = root.appendingPathComponent("current-environment")
        command(first, "builtin print -r -- ${PROFILE_CASE:-none} > " + quote(currentEnvironment.path))
        try wait("live environment") {
            (try? String(contentsOf: currentEnvironment, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "matched"
        }
        try check(true, "profile switches leave the live environment unchanged")

        var startupProfile = TerminalProfile(name: "Startup fixture")
        startupProfile.directory = secondDirectory.path
        startupProfile.startupProgram = "/bin/sh"
        let startupMarker = root.appendingPathComponent("startup-command")
        startupProfile.startupArguments = "-c 'printf profile-started > \(startupMarker.path)'"
        settings.terminalProfiles = [foreground, base, startupProfile]
        let startupSession = TerminalSession(initialDirectory: secondDirectory.path, additionalEnvironment: environment)
        let startupWindow = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 800, height: 600),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        startupWindow.contentView = startupSession.surface
        startupWindow.orderFront(nil)
        startupSession.surface.setSurfaceVisible(true)
        defer { startupSession.terminate(); startupWindow.contentView = nil; startupWindow.close() }
        try wait("new terminal startup command") {
            (try? String(contentsOf: startupMarker, encoding: .utf8)) == "profile-started"
        }
        try check(true, "startup command runs when a matching terminal is created")
        let plainMarker = root.appendingPathComponent("plain-startup-command")
        startupProfile.startupArguments = "-c 'printf profile-started > \(plainMarker.path)'"
        settings.terminalProfiles = [foreground, base, startupProfile]
        let plainSession = TerminalSession(initialDirectory: secondDirectory.path, additionalEnvironment: environment,
                                           usesConfiguredStartupCommand: false)
        defer { plainSession.terminate() }
        try check(plainSession.supportsCommandTaskShellIntegration,
                  "automation command panes skip the profile startup command")
        pumpProfiles(1)
        try check(!FileManager.default.fileExists(atPath: plainMarker.path),
                  "plain shell pane never runs the profile startup command")
        var multiline = base
        multiline.launchSettings.environmentVariables = [.init(name: "MULTI", value: "first\nBAR=second\\n\\")]
        settings.terminalProfiles = [foreground, multiline]

        TerminalProfileEditor.show(relativeTo: windows[0])
        try wait("profile editor sheet") { windows[0].attachedSheet != nil }
        let sheet = windows[0].attachedSheet!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func views() -> [NSView] { sheet.contentView.map(descendants) ?? [] }
        guard let add = views().compactMap({ $0 as? NSButton }).first(where: { $0.action == NSSelectorFromString("addProfile") }) else {
            throw NSError(domain: "profile editor add button", code: 1)
        }
        add.performClick(nil)
        let startupLabel = String(localized: "Startup program")
        guard let startup = views().compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == startupLabel }),
              let save = views().compactMap({ $0 as? NSButton }).first(where: { $0.action == NSSelectorFromString("saveProfiles") }) else {
            throw NSError(domain: "profile editor fields", code: 1)
        }
        startup.stringValue = "/remote-only/profile-executable"
        save.performClick(nil)
        try wait("profile editor save") { windows[0].attachedSheet == nil }
        try check(settings.terminalProfiles.contains { $0.startupProgram == "/remote-only/profile-executable" },
                  "editor saves a remote-only executable")
        try check(settings.terminalProfiles.first { $0.id == base.id }?.launchSettings.environmentVariables
                    == multiline.launchSettings.environmentVariables,
                  "editor keeps multiline environment values intact")
    }
}
