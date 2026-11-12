import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

// Only dependencies that can launch terminal surfaces or install into a real
// agent home are fixtures. AppSettings, TOML and config IO are production code.
@MainActor enum Theme {
    static let defaultDarkThemeName = "Default Dark"
    static let defaultLightThemeName = "Default Light"
    static var reloads = 0
    static func isCommonTheme(named: String, dark: Bool) -> Bool {
        named == (dark ? defaultDarkThemeName : defaultLightThemeName)
            || named == (dark ? "Dracula" : "GitHub")
    }
    static func reloadSelection(light: String, dark: String, terminalOnly: Bool) { reloads += 1 }
}

@MainActor final class GlobalTerminalOverlay {
    static let shared = GlobalTerminalOverlay()
    var hotkeyReloads = 0
    func reloadHotkey() { hotkeyReloads += 1 }
}

@MainActor enum IntegrationFixture {
    static var operations: [String] = []
    static var failPreflight = false
    enum Failure: Error { case unavailable }
    static func preflight(_ name: String) throws {
        operations.append(name)
        if failPreflight { throw Failure.unavailable }
    }
}

@MainActor final class AgentUsageModel {
    static let shared = AgentUsageModel()
    var policies: [[Bool]] = []
    func applySettings(_ settings: AppSettings) {
        policies.append([settings.agentUsageEnabled, settings.claudeUsageEnabled, settings.codexUsageEnabled])
    }
}

@MainActor enum ZshellAgentIntegrations {
    static func preflightInstallAvailable() throws { try IntegrationFixture.preflight("integrations-preflight-install") }
    static func preflightUninstallManaged() throws { try IntegrationFixture.preflight("integrations-preflight-uninstall") }
    static func installAvailable() throws { IntegrationFixture.operations.append("integrations-install") }
    static func uninstallManaged() throws { IntegrationFixture.operations.append("integrations-uninstall") }
}

@MainActor enum ZshellAgentLifecycleHooks {
    static func preflightInstallAvailable() throws { try IntegrationFixture.preflight("hooks-preflight-install") }
    static func preflightUninstallManaged() throws { try IntegrationFixture.preflight("hooks-preflight-uninstall") }
    static func installAvailable() throws { IntegrationFixture.operations.append("hooks-install") }
    static func uninstallManaged() throws { IntegrationFixture.operations.append("hooks-uninstall") }
}

@MainActor enum ZshellAutomationSkill {
    enum Destination: CaseIterable { case fixture }
    static func install(destinations: [Destination], force: Bool) throws -> Bool {
        IntegrationFixture.operations.append("skill-install")
        return true
    }
    static func uninstall(destinations: [Destination], force: Bool) throws -> Bool {
        IntegrationFixture.operations.append("skill-uninstall")
        return true
    }
}

@main
struct SettingsReloadTests {
    @MainActor static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    @MainActor static func wait(_ condition: () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(6)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        check(condition(), message)
    }

    @MainActor static func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
    }

    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let settings = AppSettings.shared
        let url = AppSettings.configURL
        check(url.path.hasPrefix(CommandLine.arguments[1]), "fixture config remains in disposable home")
        if CommandLine.arguments.count > 2 {
            let expectedInvalid = CommandLine.arguments[2] == "invalid-term"
            check(settings.terminalTerm == "xterm-256color" && settings.terminalTermIsInvalid == expectedInvalid,
                  "invalid startup TERM uses the default and recovered TERM stays valid after restart")
            if expectedInvalid {
                check(settings.setTerminalTerm("xterm-256color") && !settings.terminalTermIsInvalid,
                      "accepting the startup fallback clears the error")
                NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
                check(TOML.parse(at: url)?["terminal.term"] == nil,
                      "accepting the unchanged default removes the invalid startup value from disk")
            }
            print("SettingsReload: startup TERM state and persisted recovery passed (\(CommandLine.arguments[2]))")
            return
        }
        var changes = 0
        let observation = settings.objectWillChange.sink { changes += 1 }
        withExtendedLifetime(observation) {}
        wait({ FileManager.default.fileExists(atPath: url.path) }, "initial config save")
        check(!settings.focusFollowsMouse, "pointer focus is disabled by default")
        check(settings.terminalRightClickAction == .contextMenu, "right-click keeps the context menu by default")
        check(settings.shellCompletions, "shell completions are enabled by default")
        check(settings.vimCommandHints && settings.restoreTerminalHistory && settings.notifyOnError,
              "new configurations use the enabled preference defaults")
        check(settings.protectEditorSaves && settings.recoverEditorDrafts && settings.quickTerminalEnabled && settings.commandHistoryEnabled && settings.terminalTextHints
              && settings.automaticallyApplyTerminalProfiles && settings.notifyOnAgentAttention
              && settings.notifyOnAgentCompletion && settings.showPullRequestStatus,
              "feature switches preserve existing behavior by default")
        check(settings.isAtDefaults, "fresh settings expose the correct reset state")
        check(settings.terminalPaddingColor == .extend, "padding keeps automatic extension by default")
        settings.terminalPaddingColor = .background
        check(!settings.isAtDefaults, "padding policy enables reset")
        check(settings.serializedConfig().contains("terminal.padding-color = \"background\""),
              "padding policy persists")
        settings.terminalPaddingColor = .extend
        check(settings.isAtDefaults, "default padding restores reset state")
        check(settings.promptQueueEnabled && !settings.promptQueueAutoDispatch,
              "prompt queues are enabled with explicit sending by default")
        settings.promptQueueEnabled = false
        settings.promptQueueAutoDispatch = true
        check(!settings.isAtDefaults, "prompt queue settings enable reset")
        let queueConfig = TOML.parseStrictly(text: settings.serializedConfig()).values
        check(queueConfig["terminal.prompt-queue-enabled"] == .bool(false)
              && queueConfig["terminal.prompt-queue-auto-dispatch"] == .bool(true),
              "prompt queue settings export even while automatic sending is disabled by the master switch")
        settings.promptQueueEnabled = true
        settings.promptQueueAutoDispatch = false
        check(settings.promptQueueEnabled && !settings.promptQueueAutoDispatch && settings.isAtDefaults,
              "manual queue defaults restore the reset state")
        settings.applyImported(queueConfig)
        check(!settings.promptQueueEnabled && settings.promptQueueAutoDispatch,
              "import restores both prompt queue settings")
        settings.promptQueueEnabled = true
        settings.promptQueueAutoDispatch = false
        settings.terminalRightClickAction = .paste
        check(!settings.isAtDefaults, "right-click paste enables reset")
        check(settings.serializedConfig().contains("terminal.right-click-action = \"paste\""), "right-click paste persists and exports")
        var rightClickConfig = TOML.parseStrictly(text: settings.serializedConfig()).values
        rightClickConfig["terminal.right-click-action"] = .string("copy-or-paste")
        settings.applyImported(rightClickConfig)
        check(settings.terminalRightClickAction == .copyOrPaste, "right-click copy or paste imports")
        rightClickConfig["terminal.right-click-action"] = .string("invalid")
        settings.applyImported(rightClickConfig)
        check(settings.terminalRightClickAction == .contextMenu && settings.isAtDefaults, "invalid right-click action restores the default menu")
        check(!settings.agentUsageEnabled && settings.claudeUsageEnabled && settings.codexUsageEnabled,
              "account usage is opt-in while provider choices start enabled")
        let usageIntegrations = IntegrationFixture.operations
        let defaultUsageConfig = TOML.parseStrictly(text: settings.serializedConfig()).values
        var usageConfig = defaultUsageConfig
        usageConfig["ai.usage-enabled"] = .bool(true)
        usageConfig["ai.claude-usage-enabled"] = .bool(false)
        usageConfig["ai.codex-usage-enabled"] = .bool(false)
        settings.applyImported(usageConfig)
        check(AgentUsageModel.shared.policies == [[true, false, false]],
              "usage imports apply one complete policy without transient provider starts")
        let usageExport = TOML.parseStrictly(text: settings.serializedConfig()).values
        check(usageExport["ai.usage-enabled"] == .bool(true)
              && usageExport["ai.claude-usage-enabled"] == .bool(false)
              && usageExport["ai.codex-usage-enabled"] == .bool(false),
              "all usage choices serialize for export")
        settings.agentUsageEnabled = false
        check(!settings.claudeUsageEnabled && !settings.codexUsageEnabled,
              "master disable preserves provider choices")
        check(!settings.isAtDefaults, "provider choices enable reset while master is off")
        settings.applyImported(defaultUsageConfig)
        check(!settings.agentUsageEnabled && settings.claudeUsageEnabled && settings.codexUsageEnabled,
              "omitted usage keys restore safe defaults")
        check(IntegrationFixture.operations == usageIntegrations,
              "usage settings never install or uninstall agent lifecycle integration")
        check(settings.keepAwakeMode == .off, "sleep prevention is off by default")
        check(settings.sidebarDoubleClickNewSession,
              "empty-space gesture is enabled by default")
        check(settings.newSessionDirectoryPolicy == .current && settings.newSessionCustomDirectory.isEmpty,
              "new sessions inherit their current context by default")
        settings.newSessionDirectoryPolicy = .project
        check(!settings.isAtDefaults, "directory policy enables reset")
        settings.newSessionDirectoryPolicy = .current
        settings.newSessionCustomDirectory = "~/work"
        check(!settings.isAtDefaults, "retained custom directory enables reset")
        settings.newSessionCustomDirectory = ""
        check(settings.isAtDefaults, "directory preferences restore default state")
        check(settings.mouseScrollMultiplier == 1 && settings.trackpadScrollMultiplier == 1,
              "device scrolling preserves the existing speed by default")
        check(!settings.serializedConfig().contains("scroll-multiplier"), "default scroll multipliers are omitted")
        settings.mouseScrollMultiplier = 0.1
        settings.trackpadScrollMultiplier = 10
        check(!settings.isAtDefaults, "scrolling preferences enable reset")
        var scrollConfig = TOML.parseStrictly(text: settings.serializedConfig()).values
        check(scrollConfig["terminal.mouse-scroll-multiplier"]?.double == 0.1
              && scrollConfig["terminal.trackpad-scroll-multiplier"]?.double == 10,
              "independent device scrolling values persist")
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1, 10.1] {
            scrollConfig["terminal.mouse-scroll-multiplier"] = .number(invalid)
            scrollConfig["terminal.trackpad-scroll-multiplier"] = .number(invalid)
            settings.applyImported(scrollConfig)
            check(settings.mouseScrollMultiplier == 1 && settings.trackpadScrollMultiplier == 1,
                  "invalid imported scroll multipliers restore compatible defaults")
        }
        settings.mouseScrollMultiplier = .nan
        settings.trackpadScrollMultiplier = .infinity
        check(settings.isAtDefaults, "invalid direct scroll settings are normalized before persistence")
        settings.keepAwakeMode = .whileRunning
        check(!settings.isAtDefaults, "sleep prevention enables reset")
        check(settings.serializedConfig().contains("keep-awake = \"on\""), "sleep mode persists")
        var sleepConfig = TOML.parseStrictly(text: settings.serializedConfig()).values
        sleepConfig["keep-awake"] = .string("agents")
        let sleepIntegrations = IntegrationFixture.operations
        settings.applyImported(sleepConfig)
        check(settings.keepAwakeMode == .whileAgentsWork, "import changes the sleep mode")
        check(IntegrationFixture.operations == sleepIntegrations, "sleep mode does not reinstall agent integrations")
        sleepConfig["keep-awake"] = .string("invalid")
        settings.applyImported(sleepConfig)
        check(settings.keepAwakeMode == .off && settings.isAtDefaults, "invalid sleep mode falls back to off")
        settings.shellCompletions = false
        check(!settings.isAtDefaults, "disabled completions enable reset")
        wait({ (try? String(contentsOf: url, encoding: .utf8))?.contains("terminal.shell-completions = false") == true },
             "completion preference persists")
        var completionConfig = TOML.parse(at: url) ?? [:]
        completionConfig["terminal.shell-completions"] = .bool(true)
        settings.applyImported(completionConfig)
        check(settings.shellCompletions, "import restores the completion preference")
        check(settings.isAtDefaults, "restored completions restore default state")
        check(settings.terminalTerm == "xterm-256color", "missing TERM preserves the existing default")
        check(settings.setTerminalTerm("screen-256color") && !settings.isAtDefaults,
              "valid terminal type applies and enables reset")
        let termConfig = settings.serializedConfig()
        check(TOML.parseStrictly(text: termConfig).values["terminal.term"]?.string == "screen-256color",
              "terminal type serializes without losing its identity")
        for invalidTerm in ["", "xterm\nother", " xterm", "xterm ", "xterm/256", "xterm;echo", "xterm\0", "终端", String(repeating: "x", count: 129)] {
            check(!settings.setTerminalTerm(invalidTerm) && settings.terminalTerm == "screen-256color"
                  && settings.terminalTermIsInvalid, "invalid terminal type preserves the previous setting")
            check(settings.serializedConfig() == termConfig, "invalid UI values never reach the saved file")
            var invalidConfig = TOML.parseStrictly(text: termConfig).values
            invalidConfig["terminal.term"] = .string(invalidTerm)
            settings.applyImported(invalidConfig)
            check(settings.terminalTerm == "screen-256color" && settings.terminalTermIsInvalid,
                  "invalid imported terminal type retains the previous value and reports an error")
        }
        var wrongTypeConfig = TOML.parseStrictly(text: termConfig).values
        wrongTypeConfig["terminal.term"] = .number(42)
        settings.applyImported(wrongTypeConfig)
        check(settings.terminalTerm == "screen-256color" && settings.terminalTermIsInvalid,
              "wrong TOML type cannot erase the last valid terminal identity")
        settings.applyImported(TOML.parseStrictly(text: termConfig).values)
        check(settings.terminalTerm == "screen-256color" && !settings.terminalTermIsInvalid,
              "exported terminal type imports through production settings")
        check(settings.setTerminalTerm("A0.-_+") && settings.setTerminalTerm(String(repeating: "a", count: 128)),
              "allowed ASCII punctuation and length boundary are supported")
        settings.resetToDefaults()
        check(settings.terminalTerm == "xterm-256color" && settings.isAtDefaults
              && !settings.serializedConfig().contains("terminal.term"), "reset omits the default terminal type")
        settings.fileTreeDragImport = true
        check(!settings.isAtDefaults, "enabled file import enables reset")
        wait({ (try? String(contentsOf: url, encoding: .utf8))?.contains("files.drag-import = true") == true },
             "file import preference persists")
        var importConfig = TOML.parse(at: url) ?? [:]
        importConfig["files.drag-import"] = .bool(false)
        settings.applyImported(importConfig)
        check(!settings.fileTreeDragImport && settings.isAtDefaults, "import restores disabled file drag setting")
        settings.fileTreeDragImport = true
        settings.resetToDefaults()
        check(!settings.fileTreeDragImport && settings.isAtDefaults, "reset disables file drag import")
        settings.commandShortcuts[.newSession] = CommandShortcut(persistedValue: "u7a:cmd+shift")!
        check(!settings.isAtDefaults, "shortcut overrides enable reset")
        settings.resetCommandShortcuts()
        check(settings.isAtDefaults, "reset shortcuts restore default state")
        settings.quickTerminalEnabled = false
        check(settings.setCommandShortcut(CommandShortcut(character: "i", modifiers: [.command]),
                                          for: .newSession) == .quickTerminal,
              "disabled Quick Terminal still reserves its chord for re-enabling")
        check(settings.commandShortcuts.isEmpty, "conflicting recording preserves core shortcuts")
        settings.quickTerminalEnabled = true
        spin(0.4)
        let configuration = """
        app-icon = "light"
        app-presence = "dock-and-menu-bar"
        theme = "dark"
        theme-dark = "Dracula"
        theme-light = "GitHub"
        terminal.theme-only = true
        font-family = "Fixture Mono"
        terminal.font-fallback-family = "Fixture CJK"
        font-size = 19
        sidebar.font-size = 18
        sidebar.double-click-new-session = false
        interface.scale = 1.3
        toolbar.visibility = "always"
        git.proxy-enabled = true
        git.proxy = "socks5h://127.0.0.1:1080"
        terminal.font-thicken = true
        terminal.font-thicken-strength = 99
        terminal.line-height = 1.4
        terminal.mouse-scroll-multiplier = 2.5
        terminal.trackpad-scroll-multiplier = 0.5
        terminal.cell-width = 1.35
        terminal.font-features = "ss01, zero=1"
        terminal.font-ligatures = false
        terminal.cursor-shape = "underline"
        terminal.cursor-blinking = false
        terminal.macos-option-as-alt = true
        terminal.bell = false
        terminal.vim-command-hints = true
        terminal.shift-enter-newline = false
        editor.wrap-lines = false
        editor.protect-saves = false
        editor.recover-drafts = false
        editor.external-editor = "zed"
        terminal.restore-history = true
        terminal.preserve-sessions = true
        terminal.copy-on-select = false
        terminal.right-click-action = "paste"
        terminal.focus-follows-mouse = true
        terminal.background-opacity = 0.6
        terminal.background-blur = true
        terminal.padding-color = "always"
        terminal.notify-finish-seconds = 30
        terminal.notify-on-error = true
        terminal.command-history = false
        terminal.text-hints = false
        terminal.prompt-queue-enabled = false
        terminal.prompt-queue-auto-dispatch = true
        terminal.auto-profiles = false
        quick-terminal.enabled = false
        quick-terminal.size = 0.5
        quick-terminal.opacity = 0.8
        quick-terminal.shortcut = "40:256"
        quick-terminal.mode = "fresh"
        shortcuts.new-session = "u7a:cmd+shift"
        panes.show-focus-ring = false
        panes.focus-ring-opacity = 0.4
        ai.enabled = false
        ai.resume-conversations = false
        ai.notify-on-attention = false
        ai.notify-on-completion = false
        ai.usage-enabled = true
        ai.claude-usage-enabled = false
        ai.codex-usage-enabled = false
        git.pull-request-status = false
        terminal.backend = "alacritty"
        terminal.term = "screen-256color"
        terminal.startup-program = "/bin/zsh"
        terminal.startup-arguments = "-l"
        terminal.new-session-directory = "custom"
        terminal.custom-directory = "~/work"
        browser.content-blocking = false
        browser.filter-lists = "https://example.test/filter.txt"
        terminal.profiles.0.id = "71DA4706-872C-4D96-ACDC-3FC8201F86B7"
        terminal.profiles.0.name = "Fixture profile"
        terminal.profiles.0.directory = "/tmp/*"
        terminal.profiles.0.font-size = 18
        terminal.profiles.0.environment.MODE = "profile"

        """
        let parsed = TOML.parseStrictly(text: configuration)
        check(parsed.malformed == nil, "fixture is valid config")
        let oldThemeReloads = Theme.reloads
        let oldHotkeyReloads = GlobalTerminalOverlay.shared.hotkeyReloads
        settings.applyImported(parsed.values)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        let imported = settings.serializedConfig()
        let written = try SettingsConfigFile.read(at: url)
        check(written == imported, "import saves final state once")
        check(settings.terminalProfiles.first?.appearance.fontSize == 18,
              "profiles import through production settings")
        check(settings.newSessionDirectoryPolicy == .custom && settings.newSessionCustomDirectory == "~/work",
              "directory policy and path import without discarding unavailable folders")
        check(settings.terminalProfiles.first?.launchSettings.environment["MODE"] == "profile",
              "profile launch settings round trip through config")
        let roundTrip = TOML.parseStrictly(text: imported).values
        check(settings.terminalPaddingColor == .always, "import applies padding policy")
        check(settings.terminalTerm == "screen-256color", "terminal type imports into production settings")
        check(settings.terminalCellWidth == 1.35, "column spacing imports into production settings")
        check(settings.fontFeatures == "ss01, zero=1" && !settings.fontLigatures,
              "font features compose with column spacing through import and reload")
        check(settings.focusFollowsMouse && !settings.isAtDefaults, "pointer focus imports and changes default state")
        check(settings.terminalRightClickAction == .paste, "right-click action survives the full settings round trip")
        check(GitProxy.address == "socks5h://127.0.0.1:1080", "imported Git proxy reaches Git processes")
        for (key, value) in parsed.values {
            check(roundTrip[key] == value, "all persisted keys import and serialize: \(key)")
        }
        check(Theme.reloads == oldThemeReloads + 1, "import combines theme reloads")
        check(GlobalTerminalOverlay.shared.hotkeyReloads == oldHotkeyReloads + 1, "import updates hotkey once")
        check(settings.commandShortcuts[.newSession]?.persistedValue == "u7a:cmd+shift", "menu shortcuts import")
        check(IntegrationFixture.operations == ["integrations-preflight-uninstall", "hooks-preflight-uninstall", "skill-uninstall", "integrations-uninstall", "hooks-uninstall"], "import AI disable uses production lifecycle order")

        let importedIntegrations = IntegrationFixture.operations
        var withoutAI = parsed.values
        withoutAI.removeValue(forKey: "ai.enabled")
        settings.applyImported(withoutAI)
        check(!settings.aiEnabled, "import without AI preference preserves the current choice")
        check(IntegrationFixture.operations == importedIntegrations, "omitted imported AI preference does not reinstall")

        spin(0.4)
        let unchanged = changes
        let unchangedThemeReloads = Theme.reloads
        let unchangedHotkeyReloads = GlobalTerminalOverlay.shared.hotkeyReloads
        let unchangedIntegrations = IntegrationFixture.operations
        let decorated = "# preserve my hand edit\n" + imported + "unknown.example = true\n"
        try decorated.write(to: url, atomically: true, encoding: .utf8)
        spin(0.7)
        check(changes == unchanged, "same settings do not publish changes")
        check(Theme.reloads == unchangedThemeReloads, "same themes do not reload")
        check(GlobalTerminalOverlay.shared.hotkeyReloads == unchangedHotkeyReloads, "same shortcut does not re-register")
        check(IntegrationFixture.operations == unchangedIntegrations, "same AI setting does not reinstall")
        check(try SettingsConfigFile.read(at: url) == decorated, "external edits retain comments and unknown keys without writing back")

        let changed = decorated.replacingOccurrences(of: "font-size = 19", with: "font-size = 20")
        try changed.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.fontSize == 20 }, "external font edit applies")
        check(changes == unchanged + 1, "single setting edit publishes once")
        check(try SettingsConfigFile.read(at: url) == changed, "external update does not rewrite source")
        let paddingChanged = changed.replacingOccurrences(of: "terminal.padding-color = \"always\"",
                                                         with: "terminal.padding-color = \"background\"")
        try paddingChanged.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.terminalPaddingColor == .background }, "external padding edit applies")
        check(try SettingsConfigFile.read(at: url) == paddingChanged, "padding reload preserves source")
        let paddingInvalid = changed.replacingOccurrences(of: "terminal.padding-color = \"always\"",
                                                         with: "terminal.padding-color = \"invalid\"")
        try paddingInvalid.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.terminalPaddingColor == .extend }, "invalid padding policy falls back to automatic")
        let directoryChanged = changed.replacingOccurrences(of: "terminal.new-session-directory = \"custom\"",
                                                            with: "terminal.new-session-directory = \"home\"")
        try directoryChanged.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.newSessionDirectoryPolicy == .home }, "external directory policy edit applies")
        let invalidPolicy = directoryChanged.replacingOccurrences(of: "terminal.new-session-directory = \"home\"",
                                                                 with: "terminal.new-session-directory = \"unknown\"")
        try invalidPolicy.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.newSessionDirectoryPolicy == .current }, "unknown policy preserves the compatible current default")
        let termChanged = changed.replacingOccurrences(of: "terminal.term = \"screen-256color\"", with: "terminal.term = \"vt100\"")
        try termChanged.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.terminalTerm == "vt100" }, "external terminal type edit applies")
        let invalidTermEdit = termChanged.replacingOccurrences(of: "terminal.term = \"vt100\"", with: "terminal.term = \"xterm\\nother\"")
        try invalidTermEdit.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.terminalTermIsInvalid }, "invalid external terminal type reports an error")
        check(settings.terminalTerm == "vt100", "invalid external terminal type preserves the last valid value")
        check(try SettingsConfigFile.read(at: url) == invalidTermEdit, "invalid external TERM edit does not overwrite the user's buffer")
        check(settings.setTerminalTerm("vt100") && !settings.terminalTermIsInvalid,
              "accepting the unchanged terminal type clears the external edit error")
        wait({ TOML.parse(at: url)?["terminal.term"]?.string == "vt100" },
             "accepting the unchanged terminal type repairs the invalid file value")
        try invalidTermEdit.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.terminalTermIsInvalid }, "another invalid external TERM edit reports an error")
        try changed.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.terminalTerm == "screen-256color" && !settings.terminalTermIsInvalid }, "valid external TERM clears the error")
        let enabledQueue = changed.replacingOccurrences(of: "terminal.prompt-queue-enabled = false", with: "terminal.prompt-queue-enabled = true")
            .replacingOccurrences(of: "terminal.prompt-queue-auto-dispatch = true", with: "terminal.prompt-queue-auto-dispatch = false")
        try enabledQueue.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.promptQueueEnabled && !settings.promptQueueAutoDispatch }, "external edit restores manual queue mode")
        check(try SettingsConfigFile.read(at: url) == enabledQueue, "queue reload keeps external configuration intact")
        let changedScroll = enabledQueue.replacingOccurrences(of: "terminal.mouse-scroll-multiplier = 2.5", with: "terminal.mouse-scroll-multiplier = 0.1")
        try changedScroll.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.mouseScrollMultiplier == 0.1 }, "external mouse scroll edit applies live")
        check(settings.trackpadScrollMultiplier == 0.5, "mouse scroll reload leaves trackpad independent")
        let rightClickChanged = changedScroll.replacingOccurrences(of: "terminal.right-click-action = \"paste\"", with: "terminal.right-click-action = \"copy-or-paste\"")
        try rightClickChanged.write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.terminalRightClickAction == .copyOrPaste }, "external right-click edit applies to live settings")
        check(try SettingsConfigFile.read(at: url) == rightClickChanged, "external right-click update does not rewrite source")
        let usagePolicyCount = AgentUsageModel.shared.policies.count
        let usageChanged = rightClickChanged.replacingOccurrences(of: "ai.usage-enabled = true", with: "ai.usage-enabled = false")
            .replacingOccurrences(of: "ai.codex-usage-enabled = false", with: "ai.codex-usage-enabled = true")
        try usageChanged.write(to: url, atomically: true, encoding: .utf8)
        wait({ !settings.agentUsageEnabled && settings.codexUsageEnabled }, "external usage edits apply")
        check(AgentUsageModel.shared.policies.count == usagePolicyCount + 1
              && AgentUsageModel.shared.policies.last == [false, false, true],
              "external reload applies one complete usage policy")
        check(try SettingsConfigFile.read(at: url) == usageChanged, "usage reload preserves the edited file")
        check(settings.mouseScrollMultiplier == 0.1 && settings.trackpadScrollMultiplier == 0.5,
              "usage reload retains both independent scrolling choices")
        check(settings.terminalRightClickAction == .copyOrPaste, "usage reload retains the right-click action")
        for invalid in ["font-size = 23\nunfinished", "font-size = 23\ntheme = \"dark\" junk", "font-size = 23\n[]", "font-size = 23\nsidebar.font-size = nan"] {
            try invalid.write(to: url, atomically: true, encoding: .utf8)
            spin(0.6)
            check(settings.fontSize == 20, "invalid editor buffer keeps last valid settings")
        }

        try FileManager.default.removeItem(at: url)
        spin(0.5)
        check(settings.fontSize == 20, "deleted config keeps last valid settings")
        let withAI = changed.replacingOccurrences(of: "ai.enabled = false", with: "ai.enabled = true")
        IntegrationFixture.failPreflight = true
        try withAI.write(to: url, atomically: true, encoding: .utf8)
        wait({ IntegrationFixture.operations.last == "integrations-preflight-install" }, "external edit attempts AI preflight")
        check(!settings.aiEnabled, "failed preflight never applies AI flag")
        check(IntegrationFixture.operations.last == "integrations-preflight-install", "failed preflight stops install")
        check(try SettingsConfigFile.read(at: url) == withAI, "failed external preflight does not overwrite user config")
        IntegrationFixture.failPreflight = false
        try (withAI + "# retry\n").write(to: url, atomically: true, encoding: .utf8)
        wait({ settings.aiEnabled }, "valid external AI enable reaches lifecycle")
        check(Array(IntegrationFixture.operations.suffix(5)) == ["integrations-preflight-install", "hooks-preflight-install", "skill-install", "integrations-install", "hooks-install"], "external enable follows production preflight order")

        try "".write(to: url, atomically: true, encoding: .utf8)
        spin(0.4)
        check(settings.fontSize == 20, "transient empty editor file preserves current values")
        wait({ settings.fontSize == AppSettings.defaultFontSize && settings.commandShortcuts.isEmpty },
             "stable empty file applies existing-file defaults")
        check(!settings.vimCommandHints && !settings.restoreTerminalHistory && !settings.notifyOnError,
              "empty existing config preserves the legacy omitted-key defaults")
        check(!settings.focusFollowsMouse, "pointer focus resets on external config reload")
        check(settings.sidebarDoubleClickNewSession,
              "omitted sidebar gesture key restores the default on external reload")
        check(settings.newSessionDirectoryPolicy == .current && settings.newSessionCustomDirectory.isEmpty,
              "empty config resets both directory preferences")
        check(settings.terminalTerm == "xterm-256color" && !settings.terminalTermIsInvalid,
              "missing terminal type on reload restores the compatible default")
        check(settings.promptQueueEnabled && !settings.promptQueueAutoDispatch,
              "omitted queue settings restore explicit sending without automatic replay")
        check(settings.mouseScrollMultiplier == 1 && settings.trackpadScrollMultiplier == 1,
              "omitted scroll preferences restore compatible defaults on reload")
        check(settings.terminalRightClickAction == .contextMenu, "omitted right-click action restores the menu on external reload")
        check(!settings.gitProxyEnabled && settings.gitProxyAddress == GitProxy.defaultAddress && GitProxy.address == nil,
              "Git proxy resets to off with the default address prefilled")
        check(try SettingsConfigFile.read(at: url) == "", "default reload leaves empty source unchanged")
        check(settings.protectEditorSaves && settings.recoverEditorDrafts && settings.quickTerminalEnabled && settings.commandHistoryEnabled && settings.terminalTextHints
              && settings.automaticallyApplyTerminalProfiles && settings.notifyOnAgentAttention
              && settings.notifyOnAgentCompletion && settings.showPullRequestStatus,
              "omitted feature switches restore compatible defaults on external reload")
        check(!settings.agentUsageEnabled && settings.claudeUsageEnabled && settings.codexUsageEnabled,
              "empty configuration disables usage and restores provider defaults")

        settings.resetToDefaults()
        check(settings.isAtDefaults, "reset covers every configurable preference")
        check(settings.terminalPaddingColor == .extend, "reset restores automatic padding")
        let featureSwitches: [ReferenceWritableKeyPath<AppSettings, Bool>] = [
            \.protectEditorSaves, \.recoverEditorDrafts, \.quickTerminalEnabled, \.commandHistoryEnabled, \.terminalTextHints, \.promptQueueEnabled,
            \.automaticallyApplyTerminalProfiles, \.notifyOnAgentAttention,
            \.notifyOnAgentCompletion, \.showPullRequestStatus, \.sidebarDoubleClickNewSession,
            \.claudeUsageEnabled, \.codexUsageEnabled,
        ]
        for keyPath in featureSwitches {
            settings[keyPath: keyPath] = false
            check(!settings.isAtDefaults, "each feature switch enables reset")
            settings[keyPath: keyPath] = true
        }
        check(settings.isAtDefaults, "restored feature switches restore default state")
        settings.agentUsageEnabled = true
        check(!settings.isAtDefaults, "enabled usage changes reset state")
        settings.resetToDefaults()
        check(!settings.agentUsageEnabled && settings.isAtDefaults, "reset disables usage")

        settings.terminalCellWidth = 1.333
        check(settings.terminalCellWidth == 1.33 && !settings.isAtDefaults,
              "column spacing uses shared whole percentages and enables reset")
        for invalidWidth in [Double.nan, Double.infinity, 0.5, 3] {
            settings.terminalCellWidth = invalidWidth
            check(settings.terminalCellWidth == 1, "invalid direct spacing restores native width")
            settings.applyImported(["terminal.cell-width": .number(invalidWidth)])
            check(settings.terminalCellWidth == 1, "invalid imported spacing restores native width")
        }
        settings.terminalCellWidth = 1.5
        settings.fontFeatures = "ss01, zero=1"
        settings.fontLigatures = false
        settings.resetFont()
        check(settings.terminalCellWidth == 1 && !settings.serializedConfig().contains("terminal.cell-width"),
              "font reset restores column spacing and omits the default config key")
        check(settings.fontFeatures.isEmpty && settings.fontLigatures,
              "font reset also restores features after combined spacing changes")

        for size in 8...32 { settings.fontSize = Double(size) }
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        check(TOML.parse(at: url)?["font-size"]?.double == 32, "termination flush saves last UI update")
        check(Theme.reloads == unchangedThemeReloads + 1, "reset reloads changed themes once")
        print("SettingsReload: all \(parsed.values.count) config keys, changed-only publication, theme/hotkey batching, invalid/delete/empty edits, AI contracts and termination flush passed")
        withExtendedLifetime(observation) {}
    }
}
