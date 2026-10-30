import Foundation

struct SettingsSearchResult: Equatable {
    let category: SettingsCategory
    let title: String
    let section: String?
    let searchText: String
}

enum SettingsSearchIndex {
    static func results(for query: String) -> [SettingsSearchResult] {
        let terms = normalize(query).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return [] }
        return entries.filter { entry in
            let text = normalize(entry.searchText)
            return terms.allSatisfy { text.contains($0) }
        }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: AppLocalization.current.locale)
    }

    // Search must not construct panes: opening Recommendations starts tool
    // checks, and opening AI refreshes account usage.
    private static var entries: [SettingsSearchResult] {
        let theme = String(localized: "Theme")
        let colors = String(localized: "Colors")
        let font = String(localized: "Font")
        let interface = String(localized: "Interface")
        let panes = String(localized: "Panes")
        let cursor = String(localized: "Cursor")
        let background = String(localized: "Background")
        let behavior = String(localized: "Behavior")
        let notifications = String(localized: "Command Notifications")
        let quickTerminal = String(localized: "Quick Terminal")
        let shortcuts = String(localized: "Shortcuts")
        let tools = String(localized: "Manage Tools")

        func item(
            _ category: SettingsCategory,
            _ title: String,
            section: String? = nil,
            description: String = "",
            keywords: String = ""
        ) -> SettingsSearchResult {
            SettingsSearchResult(
                category: category,
                title: title,
                section: section,
                searchText: [category.title, category.rawValue, section ?? "", title, description, keywords]
                    .joined(separator: " ")
            )
        }

        var result = SettingsCategory.allCases.filter { $0 != .automation }.map { item($0, $0.title) }
        result += [
            item(.browser, String(localized: "Block ads and trackers"), keywords: "browser.content-blocking ads trackers privacy"),
            item(.browser, String(localized: "Filter Lists"), section: String(localized: "Filter Lists"), keywords: "browser.filter-lists EasyList EasyPrivacy ABP custom URL"),
            item(.browser, String(localized: "Update Lists Now")),
            item(.general, String(localized: "Language"),
                 keywords: AppLanguage.allCases.map(\.title).joined(separator: " ")),
            item(.general, String(localized: "Show Zshell in"),
                 description: String(localized: "With a menu bar icon, closing the last workspace window keeps its terminals running."),
                 keywords: "app-presence Dock " + ApplicationPresence.allCases.map(\.title).joined(separator: " ")),
            item(.general, String(localized: "Toolbar"), description: [
                String(localized: "Shows the toolbar only in Git repositories"),
                String(localized: "Shows the toolbar in every project"),
                String(localized: "Keeps the toolbar hidden"),
            ].joined(separator: " "), keywords: "toolbar.visibility"),
            item(.general, String(localized: "Use proxy for Git"), section: String(localized: "Git"),
                 description: String(localized: "Applies to Git panel actions, pull request status, and Git in terminals opened afterwards."),
                 keywords: "git.proxy-enabled proxy network gh GitHub"),
            item(.general, String(localized: "Proxy address"), section: String(localized: "Git"),
                 keywords: "git.proxy proxy http https socks"),
            item(.general, String(localized: "Reset to Defaults")),
            item(.appearance, theme, section: theme),
            item(.appearance, String(localized: "Dock icon"), section: String(localized: "App Icon"),
                 keywords: "app-icon"),
            item(.appearance, String(localized: "Dark theme"), section: colors, keywords: "theme-dark"),
            item(.appearance, String(localized: "Light theme"), section: colors, keywords: "theme-light"),
            item(.appearance, String(localized: "Terminal theme only"), section: colors,
                 description: String(localized: "Keep the window, sidebars, and editor on Zshell’s default colors"),
                 keywords: "terminal.theme-only"),
            item(.appearance, String(localized: "Latin family"), section: font, keywords: "font-family"),
            item(.appearance, String(localized: "CJK fallback"), section: font,
                 description: String(localized: "Used after the Latin family and before the bundled symbol font"),
                 keywords: "terminal.font-fallback-family"),
            item(.appearance, String(localized: "Size"), section: font, keywords: "font-size"),
            item(.appearance, String(localized: "Line height"), section: font, keywords: "terminal.line-height"),
            item(.appearance, String(localized: "Thicken font strokes"), section: font,
                 description: String(localized: "Renders terminal text with slightly heavier strokes, like classic macOS font smoothing"),
                 keywords: "terminal.font-thicken"),
            item(.appearance, String(localized: "Stroke strength"), section: font,
                 keywords: "terminal.font-thicken-strength"),
            item(.appearance, String(localized: "Interface size"), section: interface, keywords: "interface.scale"),
            item(.appearance, String(localized: "Font size"), section: interface, keywords: "sidebar.font-size"),
            item(.appearance, String(localized: "Show focus ring on active pane"), section: panes,
                 description: String(localized: "Draws an accent outline around the focused pane when a tab is split"),
                 keywords: "panes.show-focus-ring"),
            item(.appearance, String(localized: "Opacity"), section: panes,
                 description: String(localized: "Pane focus ring opacity"), keywords: "panes.focus-ring-opacity"),
            item(.terminal, String(localized: "Startup"), description: [
                String(localized: "Changes apply only to new terminals. Open terminals keep their current process."),
                String(localized: "Login shell"), String(localized: "Custom program"),
                String(localized: "Startup program"), String(localized: "Startup arguments"),
                String(localized: "Uses your account login shell with its login startup files."),
                String(localized: "Arguments are parsed without a shell. Quotes and backslashes preserve argument boundaries."),
                String(localized: "Enter the full path to an executable file. New terminals use your login shell until the path is valid."),
                String(localized: "Close every quote and do not end arguments with a backslash. New terminals use your login shell until the arguments are valid."),
            ].joined(separator: " "), keywords: "terminal.startup-program terminal.startup-arguments"),
            item(.terminal, String(localized: "Cursor shape"), section: cursor,
                 keywords: "terminal.cursor-shape"),
            item(.terminal, String(localized: "Blink cursor"), section: cursor,
                 keywords: "terminal.cursor-blinking"),
            item(.terminal, String(localized: "Opacity"), section: background,
                 description: String(localized: "Terminal background opacity"),
                 keywords: "terminal.background-opacity"),
            item(.terminal, String(localized: "Blur behind window"), section: background,
                 description: String(localized: "Adds frosted material behind translucent terminal backgrounds"),
                 keywords: "terminal.background-blur"),
            item(.terminal, String(localized: "Vim command hints"), section: behavior,
                 description: String(localized: "Show common Vim and Neovim commands in Info, ordered by the visible editor mode, including over SSH."),
                 keywords: "terminal.vim-command-hints"),
            item(.terminal, String(localized: "Shell completions"), section: behavior,
                 description: String(localized: "Suggest commands and arguments in new zsh terminals. Tab shows candidates; Right accepts a suggestion; Esc dismisses it. Existing shell plugins keep their bindings."),
                 keywords: "terminal.shell-completions zsh autosuggestions Tab arguments"),
            item(.terminal, String(localized: "Use Option as Alt/Meta"), section: behavior,
                 description: String(localized: "Sends Option-key combinations to terminal programs as Meta shortcuts instead of macOS text input"),
                 keywords: "terminal.macos-option-as-alt"),
            item(.terminal, String(localized: "Terminal bell"), section: behavior,
                 description: String(localized: "Plays the alert sound and uses macOS visual alerts when terminal programs ring the bell"),
                 keywords: "terminal.bell"),
            item(.terminal, String(localized: "Shift+Enter inserts a newline"), section: behavior,
                 description: String(localized: "Lets coding agents insert a new line with Shift+Enter while Enter still submits the prompt"),
                 keywords: "terminal.shift-enter-newline"),
            item(.terminal, String(localized: "Restore session history on relaunch"), section: behavior,
                 description: String(localized: "Reopened terminals show their previous scrollback above a fresh shell"),
                 keywords: "terminal.restore-history"),
            item(.terminal, String(localized: "Copy on select"), section: behavior,
                 description: String(localized: "Copies selected terminal text to the clipboard when you finish dragging"),
                 keywords: "terminal.copy-on-select"),
            item(.terminal, String(localized: "Focus follows mouse"), section: behavior,
                 description: String(localized: "Focuses a terminal pane when you move the pointer into it"),
                 keywords: "terminal.focus-follows-mouse pointer hover"),
            item(.terminal, String(localized: "Long-running commands"), section: notifications,
                 description: String(localized: "Notify when a command runs at least this long and then finishes. Changes apply to zsh terminals opened afterwards."),
                 keywords: "terminal.notify-finish-seconds"),
            item(.terminal, String(localized: "Failed commands"), section: notifications,
                 description: String(localized: "Notify when a command exits with a failure, no matter how briefly it ran. Changes apply to zsh terminals opened afterwards."),
                 keywords: "terminal.notify-on-error"),
            item(.terminal, String(localized: "Shortcut"), section: quickTerminal, keywords: "quick-terminal.shortcut"),
            item(.terminal, String(localized: "Session behavior"), section: quickTerminal, keywords: "quick-terminal.mode reuse fresh workspace"),
            item(.terminal, String(localized: "Size"), section: quickTerminal,
                 description: String(localized: "Quick Terminal default size"), keywords: "quick-terminal.size"),
            item(.terminal, String(localized: "Opacity"), section: quickTerminal,
                 description: String(localized: "Quick Terminal default opacity"), keywords: "quick-terminal.opacity"),
            item(.editor, String(localized: "External editor"), keywords: "editor.external-editor"),
            item(.editor, String(localized: "Wrap lines to editor width"), keywords: "editor.wrap-lines"),
            item(.automation, String(localized: "AI"),
                 description: String(localized: "Lets agents delegate work and coordinate across Zshell panes"),
                 keywords: "ai.enabled Claude Codex"),
            item(.recommendations, "Homebrew", section: tools,
                 description: [
                    String(localized: "Tools are downloaded, installed, and updated through your Homebrew installation."),
                    String(localized: "Install Homebrew, then click Refresh to enable one-click installation."),
                 ].joined(separator: " ")),
            item(.recommendations, String(localized: "Refresh"), section: tools),
            item(.recommendations, String(localized: "Install Missing"), section: tools),
            item(.recommendations, String(localized: "Update All"), section: tools),
            item(.updates, String(localized: "Automatically check for updates")),
            item(.updates, String(localized: "Automatically download updates"),
                 description: String(localized: "Downloads updates in the background. If automatic installation is off, updates install when you quit Zshell.")),
            item(.updates, String(localized: "Automatically install updates"),
                 description: String(localized: "Installs downloaded updates and restarts Zshell automatically. Running terminal processes will stop.")),
            item(.updates, String(localized: "Check for Updates…")),
            item(.shortcuts, String(localized: "Restore Default Shortcuts")),
        ]

        for option in AppTheme.allCases {
            result.append(item(.appearance, option.title, section: theme, keywords: "theme"))
        }
        if TerminalBackend.selectable.count > 1 {
            result.append(item(.terminal, String(localized: "Backend"),
                               description: String(localized: "Changes apply only to new terminals. Open shells keep their current backend."),
                               keywords: "terminal.backend Ghostty Alacritty"))
        }
        result += AppCommand.allCases.map { item(.shortcuts, $0.title, section: shortcuts, keywords: $0.rawValue) }
        result += RecommendedTool.allCases.map {
            item(.recommendations, $0.name, section: $0.group.title, description: $0.purpose, keywords: $0.executableName)
        }
        return result
    }
}
