import AppKit
import Darwin
import Foundation
@testable import zshell

@main
@MainActor
struct AgentUsageSettingsSurfaceTests {
    private static var terminal: TerminalSession?
    private static var checks = 0

    private static func pump(_ duration: TimeInterval = 0.03) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    private static func stopEventLoop() {
        NSApp.stop(nil)
        // A timer's stop does not wake AppKit's blocked next-event wait.
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            subtype: 0, data1: 0, data2: 0)!, atStart: true)
    }

    private static func check(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
        print("PASS \(CommandLine.arguments[1]): \(message)")
    }

    private static func wait(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { pump() }
        check(condition(), message)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func toggle(_ title: String, in window: NSWindow) -> NSSwitch {
        descendants(window.contentView!).compactMap { $0 as? NSSwitch }
            .first { $0.accessibilityLabel() == title }!
    }

    private static func report(_ percent: Double) -> ZshellJSONValue {
        .object(["windows": .object(["five_hour": .object([
            "used_percentage": .number(percent),
            "resets_at": .number(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])])])
    }

    static func main() throws {
        setbuf(stdout, nil)
        let visible = CommandLine.arguments.contains("--visible")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(visible ? .regular : .prohibited)
        if !visible { QuickTerminalOffscreen.install() }
        TerminalFont.registerBundledFonts()
        AppLocalization.apply(.english)
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath()
        let settings = AppSettings.shared
        if visible { NSApp.finishLaunching() }
        check(AppSettings.configURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
              "production settings use isolated home")
        settings.terminalBackend = CommandLine.arguments[1] == "ghostty" ? .libghostty : .alacritty
        check(!settings.aiEnabled && !settings.agentUsageEnabled && settings.claudeUsageEnabled && settings.codexUsageEnabled,
              "safe fixture keeps AI integration and account reads off")
        let initialConfig = settings.serializedConfig()
        let controller = SettingsWindowController.shared
        controller.show(category: .automation)
        let window = controller.window!
        if visible {
            window.title = "Agent Usage Settings — \(CommandLine.arguments[1])"
            window.setContentSize(NSSize(width: 900, height: 690))
            window.center()
        }
        pump(0.2)
        let master = toggle(String(localized: "Read account usage"), in: window)
        let claude = toggle(String(localized: "Read Claude Code usage"), in: window)
        let codex = toggle(String(localized: "Read Codex usage"), in: window)
        check(master.isEnabled && master.state == .off && !claude.isEnabled && !codex.isEnabled,
              "real Settings always exposes master and retained provider choices without usage")
        check(SettingsSearchIndex.results(for: "ai.usage-enabled").contains { $0.title == String(localized: "Read account usage") },
              "real Settings search discovers usage while AI is disabled")
        // No application delegate or integration reconciliation runs in this
        // fixture. The terminal only checks that both renderers remain usable.
        let session = TerminalSession(commandArguments: ["/bin/cat"], allowsPersistence: false,
            usesConfiguredStartupCommand: false, usesConfiguredInitializationCommand: false)
        terminal = session
        let surface = session.surface
        surface.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let terminalWindow = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        terminalWindow.isReleasedWhenClosed = false
        terminalWindow.contentView = surface
        surface.setSurfaceVisible(false)
        defer {
            settings.agentUsageEnabled = false
            // Visible reviewers may change provider choices before reusing this home.
            settings.applyImported(TOML.parseStrictly(text: initialConfig).values)
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            session.terminate()
            pump(0.2)
            terminalWindow.contentView = nil
            terminalWindow.close()
        }
        wait("test terminal launches without account or authorization prompts") { session.shellPid != nil }
        if visible {
            let closed = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { stopEventLoop() }
            }
            let timeout = Timer.scheduledTimer(withTimeInterval: 900, repeats: false) { _ in
                MainActor.assumeIsolated { window.close() }
            }
            DispatchQueue.main.async {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                let onScreen = windows.contains {
                    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
                        && ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber
                }
                check(window.isVisible && onScreen, "manual Settings window is on screen")
                print("VISIBLE_READY pid=\(getpid()) backend=\(CommandLine.arguments[1]) visible=\(window.isVisible) on_screen=\(onScreen) settings=\(AppSettings.configURL.path)")
            }
            // Pumping Foundation's RunLoop does not dispatch AppKit input or
            // flush window drawing. Manual acceptance needs the native loop.
            NSApp.run()
            timeout.invalidate()
            NotificationCenter.default.removeObserver(closed)
            controller.close()
            return
        }

        let usage = AgentUsageModel.shared
        check(!usage.acceptClaudeStatusLine(report(44)), "master-off model rejects reports")
        let usagePath = root.appendingPathComponent("usage/claude.json")
        check(!FileManager.default.fileExists(atPath: usagePath.path), "master-off creates no usage report")
        master.performClick(nil)
        pump(0.1)
        check(settings.agentUsageEnabled && claude.isEnabled && codex.isEnabled, "real master switch enables provider controls")
        wait("isolated providers finish their first refresh") { !usage.claude.isRefreshing && !usage.codex.isRefreshing }
        check(usage.claude.availability == .unavailable(.noClaudeSession), "missing local Claude report remains explicit")
        check(usage.codex.availability == .unavailable(.notSignedIn), "stand-in CLI reports sign-in absence without prompting")
        check(usage.acceptClaudeStatusLine(report(66)), "enabled real model saves local stand-in usage")
        let saved = try Data(contentsOf: usagePath)
        claude.performClick(nil)
        pump(0.08)
        check(!settings.claudeUsageEnabled && usage.claude.availability == .disabled,
              "real provider switch immediately hides and disables reading")
        check(!usage.acceptClaudeStatusLine(report(90)), "provider-off model rejects report")
        check((try Data(contentsOf: usagePath)) == saved, "provider-off report cannot write")
        master.performClick(nil)
        pump(0.08)
        check(!settings.agentUsageEnabled && !settings.claudeUsageEnabled && settings.codexUsageEnabled,
              "real master off retains provider choices")
        check(usage.claude.availability == .disabled && usage.codex.availability == .disabled,
              "real master off clears displayed provider data")
        let started = root.appendingPathComponent("cli-starts")
        let starts = try Data(contentsOf: started)
        usage.refresh()
        usage.refreshIfNeeded()
        pump(0.1)
        check((try Data(contentsOf: started)) == starts, "master-off refresh cannot spawn CLI")
        var imported = TOML.parseStrictly(text: initialConfig).values
        imported["ai.usage-enabled"] = .bool(true)
        imported["ai.claude-usage-enabled"] = .bool(false)
        imported["ai.codex-usage-enabled"] = .bool(false)
        settings.applyImported(imported)
        pump(0.1)
        check(master.state == .on && claude.state == .off && codex.state == .off,
              "import synchronizes real AppKit controls")
        check(usage.claude.availability == .disabled && usage.codex.availability == .disabled,
              "import does not transiently read disabled providers")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        let exported = settings.serializedConfig()
        check((try SettingsConfigFile.read(at: AppSettings.configURL)) == exported,
              "usage export matches production saved configuration")
        let changed = exported.replacingOccurrences(of: "ai.usage-enabled = true", with: "ai.usage-enabled = false")
        try changed.write(to: AppSettings.configURL, atomically: true, encoding: .utf8)
        wait("external config reload synchronizes usage controls") { !settings.agentUsageEnabled && master.state == .off }
        check((try SettingsConfigFile.read(at: AppSettings.configURL)) == changed, "external reload leaves edited config intact")
        settings.applyImported(TOML.parseStrictly(text: initialConfig).values)
        pump(0.1)
        check(!settings.agentUsageEnabled && settings.claudeUsageEnabled && settings.codexUsageEnabled,
              "safe defaults restore all three controls")
        check(session.shellPid != nil && !session.hasExited, "both terminal backends remain alive through usage settings changes")
        controller.close()
        let loopStart = Date()
        let shutdown = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { stopEventLoop() }
        }
        NSApp.run()
        shutdown.invalidate()
        check(Date().timeIntervalSince(loopStart) < 2, "timer shutdown wakes the native event loop without user input")
        check(QuickTerminalOffscreen.isSafe(), "automatic surface test never focuses user desktop")
        print("Agent usage production settings: \(checks) checks passed")
    }
}
