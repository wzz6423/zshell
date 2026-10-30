import Foundation

struct SettingsSearchResult: Equatable {
    let category: SettingsCategory
    let title: String
    let section: String?
    let searchText: String
}

enum SettingsSearchIndex {
    @MainActor static func results(for query: String) -> [SettingsSearchResult] {
        results(for: query, visibility: .current)
    }

    static func results(for query: String, visibility: SettingsVisibility) -> [SettingsSearchResult] {
        let terms = normalize(query).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return [] }
        return entries(visibility: visibility).filter { entry in
            let text = normalize(entry.searchText)
            return terms.allSatisfy { text.contains($0) }
        }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: AppLocalization.current.locale)
    }

    // Search must not construct panes: opening Recommendations starts tool
    // checks, and opening AI refreshes account usage.
    private static func entries(visibility: SettingsVisibility) -> [SettingsSearchResult] {
        let theme = String(localized: "Theme")
        let colors = String(localized: "Colors")
        let font = String(localized: "Font")
        let interface = String(localized: "Interface")
        let panes = String(localized: "Panes")
        let cursor = String(localized: "Cursor")
        let background = String(localized: "Background")
        let input = String(localized: "Input")
        let history = String(localized: "History")
        let profiles = String(localized: "Terminal Profiles")
        let notifications = String(localized: "Notifications")
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
            item(.browser, String(localized: "Import Browser Data…"), keywords: "browser import cookies Chrome Firefox"),
            item(.browser, String(localized: "Imported Browser History"), keywords: "browser imported history"),
            item(.general, String(localized: "Language"),
                 keywords: AppLanguage.allCases.map(\.title).joined(separator: " ")),
            item(.general, String(localized: "Show Zshell in"),
                 description: String(localized: "With a menu bar icon, closing the last workspace window keeps its terminals running."),
                 keywords: "app-presence Dock " + ApplicationPresence.allCases.map(\.title).joined(separator: " ")),
            item(.general, String(localized: "Toolbar"), keywords: "toolbar.visibility"),
            item(.general, String(localized: "Use proxy for Git"), section: String(localized: "Git"),
                 description: String(localized: "Applies to Git panel actions, pull request status, and Git in terminals opened afterwards."),
                 keywords: "git.proxy-enabled proxy network gh GitHub"),
            item(.general, String(localized: "Show pull request status"), section: String(localized: "Git"),
                 keywords: "git.pull-request-status GitHub PR"),
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
            item(.appearance, String(localized: "CJK fallback"), section: font, keywords: "terminal.font-fallback-family"),
            item(.appearance, String(localized: "Size"), section: font, keywords: "font-size"),
            item(.appearance, String(localized: "Line height"), section: font, keywords: "terminal.line-height"),
            item(.appearance, String(localized: "Thicken font strokes"), section: font, keywords: "terminal.font-thicken"),
            item(.appearance, String(localized: "Interface size"), section: interface, keywords: "interface.scale"),
            item(.appearance, String(localized: "Font size"), section: interface, keywords: "sidebar.font-size"),
            item(.appearance, String(localized: "Show focus ring on active pane"), section: panes, keywords: "panes.show-focus-ring"),
            item(.terminal, String(localized: "Startup"), description: [
                String(localized: "Changes apply only to new terminals. Open terminals keep their current process."),
                String(localized: "Login shell"), String(localized: "Custom program"),
                String(localized: "Startup program"), String(localized: "Startup arguments"),
            ].joined(separator: " "), keywords: "terminal.startup-program terminal.startup-arguments"),
            item(.terminal, String(localized: "Workspace Templates…"), keywords: "workspace templates startup layout"),
            item(.terminal, String(localized: "Apply terminal profiles automatically"), section: profiles,
                 keywords: "terminal.auto-profiles automatic profiles detection"),
            item(.terminal, String(localized: "Manage Terminal Profiles…"), section: profiles, keywords: "profiles theme font startup"),
            item(.appearance, String(localized: "Cursor shape"), section: cursor,
                 keywords: "terminal.cursor-shape"),
            item(.appearance, String(localized: "Blink cursor"), section: cursor,
                 keywords: "terminal.cursor-blinking"),
            item(.appearance, String(localized: "Opacity"), section: background,
                 description: String(localized: "Terminal background opacity"),
                 keywords: "terminal.background-opacity"),
            item(.terminal, String(localized: "Show terminal text hints"), section: input,
                 keywords: "terminal.text-hints text suggestion overlay"),
            item(.terminal, String(localized: "Vim command hints"), section: input, keywords: "terminal.vim-command-hints Neovim SSH"),
            item(.terminal, String(localized: "Shell completions"), section: input,
                 keywords: "terminal.shell-completions zsh autosuggestions Tab arguments"),
            item(.terminal, String(localized: "Use Option as Alt/Meta"), section: input, keywords: "terminal.macos-option-as-alt"),
            item(.terminal, String(localized: "Terminal bell"), section: notifications, keywords: "terminal.bell"),
            item(.terminal, String(localized: "Shift+Enter inserts a newline"), section: input, keywords: "terminal.shift-enter-newline"),
            item(.terminal, String(localized: "Keep sessions running after quitting"),
                 description: String(localized: "New terminals keep shells, agents, and servers running when Zshell quits. Closing a pane ends its tasks. Turn this off before quitting to end all sessions."),
                 keywords: "terminal.preserve-sessions"),
            item(.terminal, String(localized: "Record command history"), section: history, keywords: "terminal.command-history"),
            item(.terminal, String(localized: "Command History…"), section: history, keywords: "command history search"),
            item(.terminal, String(localized: "Restore session history on relaunch"), section: history,
                 description: String(localized: "Reopened terminals show their previous scrollback above a fresh shell"),
                 keywords: "terminal.restore-history"),
            item(.terminal, String(localized: "Copy on select"), section: input, keywords: "terminal.copy-on-select clipboard"),
            item(.terminal, String(localized: "Focus follows mouse"), section: input,
                 keywords: "terminal.focus-follows-mouse pointer hover"),
            item(.terminal, String(localized: "Long-running commands"), section: notifications,
                 description: String(localized: "Changes apply to new zsh terminals."),
                 keywords: "terminal.notify-finish-seconds"),
            item(.terminal, String(localized: "Failed commands"), section: notifications,
                 description: String(localized: "Changes apply to new zsh terminals."),
                 keywords: "terminal.notify-on-error"),
            item(.terminal, String(localized: "Notification History…"), section: notifications, keywords: "notification history"),
            item(.terminal, String(localized: "Enable Quick Terminal"), section: quickTerminal, keywords: "quick-terminal.enabled"),
            item(.editor, String(localized: "External editor"), keywords: "editor.external-editor"),
            item(.editor, String(localized: "Wrap lines to editor width"), keywords: "editor.wrap-lines"),
            item(.automation, String(localized: "AI"),
                 description: String(localized: "Lets agents delegate work and coordinate across Zshell panes"),
                 keywords: "ai.enabled Claude Codex"),
            item(.automation, String(localized: "Agent Conversation History"), keywords: "agent conversations Claude Codex Pi OpenCode history"),
            item(.recommendations, "Homebrew", section: tools,
                 description: [
                    String(localized: "Tools are downloaded, installed, and updated through your Homebrew installation."),
                    String(localized: "Install Homebrew, then click Refresh to enable one-click installation."),
                 ].joined(separator: " ")),
            item(.recommendations, String(localized: "Refresh"), section: tools),
            item(.updates, String(localized: "Automatically check for updates")),
            item(.updates, String(localized: "Check for Updates…")),
            item(.shortcuts, String(localized: "Restore Default Shortcuts")),
        ]

        if visibility.recommendations.installMissing {
            result.append(item(.recommendations, String(localized: "Install Missing"), section: tools))
        }
        if visibility.recommendations.updateAll {
            result.append(item(.recommendations, String(localized: "Update All"), section: tools))
        }
        if visibility.browserContentBlocking {
            result += [
                item(.browser, String(localized: "Filter Lists"), section: String(localized: "Filter Lists"), keywords: "browser.filter-lists EasyList EasyPrivacy ABP custom URL"),
                item(.browser, String(localized: "Update Lists Now")),
            ]
        }
        if visibility.gitProxyEnabled {
            result.append(item(.general, String(localized: "Proxy address"), section: String(localized: "Git"),
                               description: String(localized: "HTTP, HTTPS, or SOCKS proxy URL. Changes apply to terminals opened afterwards."),
                               keywords: "git.proxy proxy http https socks"))
        }
        if visibility.fontThicken {
            result.append(item(.appearance, String(localized: "Stroke strength"), section: font,
                               keywords: "terminal.font-thicken-strength"))
        }
        if visibility.showPaneFocusRing {
            result.append(item(.appearance, String(localized: "Opacity"), section: panes,
                               description: String(localized: "Pane focus ring opacity"), keywords: "panes.focus-ring-opacity"))
        }
        if visibility.terminalBackgroundBlur {
            result.append(item(.appearance, String(localized: "Blur behind window"), section: background,
                               keywords: "terminal.background-blur"))
        }
        if visibility.quickTerminalEnabled {
            result += [
                item(.terminal, String(localized: "Shortcut"), section: quickTerminal, keywords: "quick-terminal.shortcut"),
                item(.terminal, String(localized: "Session behavior"), section: quickTerminal, keywords: "quick-terminal.mode reuse fresh workspace"),
                item(.terminal, String(localized: "Size"), section: quickTerminal,
                     description: String(localized: "Quick Terminal default size"), keywords: "quick-terminal.size"),
                item(.terminal, String(localized: "Opacity"), section: quickTerminal,
                     description: String(localized: "Quick Terminal default opacity"), keywords: "quick-terminal.opacity"),
            ]
        }
        if visibility.aiEnabled {
            result += [
                item(.automation, String(localized: "Resume agent conversations"), keywords: "ai.resume-conversations restore relaunch"),
                item(.automation, String(localized: "Notify when agents need attention"), section: notifications,
                     keywords: "ai.notify-on-attention pending input approval"),
                item(.automation, String(localized: "Notify when agents finish"), section: notifications,
                     keywords: "ai.notify-on-completion completed"),
            ]
        }
        if visibility.automaticUpdateDownloads {
            result.append(item(.updates, String(localized: "Automatically download updates"),
                               description: String(localized: "Downloads updates in the background. If automatic installation is off, updates install when you quit Zshell.")))
        }
        if visibility.automaticUpdateInstallation {
            result.append(item(.updates, String(localized: "Automatically install updates"),
                               description: String(localized: "Installs downloaded updates and restarts Zshell automatically. Running terminal processes will stop.")))
        }

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
