//
//  ZshellTerminalView+Ghostty.swift
//  zshell
//

import AppKit
import GhosttyTerminal
import GhosttyTheme

/// The libghostty half of Zshell's terminal backend: starting the emulator,
/// rendering Zshell's settings into Ghostty's config, and translating Ghostty's
/// delegate callbacks into ``TerminalBackendEvents``.
///
/// Nothing above `ZshellTerminalView` names a Ghostty type, so a second backend
/// only has to satisfy ``TerminalBackendSurface`` — it does not have to
/// re-implement any of this.
extension ZshellTerminalView {
    // MARK: - Lifecycle

    func start(launch: TerminalLaunch) {
        launchCommand = launch.commandLine
        launchShellIntegration = Self.shellIntegration(for: launch.interactiveShell)
        supportsInputSelection = launch.usesZsh
        let controller = TerminalController(
            configSource: .none,
            theme: Self.ghosttyTheme(),
            terminalConfiguration: terminalConfiguration(command: launch.commandLine)
        )
        ghosttyController = controller
        delegate = self
        configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: launch.workingDirectory,
            envVars: launch.environment
        )
        self.controller = controller
        applyAppearance()
    }

    /// Reconfigures libghostty in place when appearance, font, or terminal
    /// input settings change. Ghostty also uses these values for OSC 10/11
    /// queries, so reported defaults always match the visible theme.
    func applyAppearance() {
        guard let ghosttyController else { return }
        _ = ghosttyController.setTerminalConfiguration(
            terminalConfiguration(command: launchCommand)
        )
        _ = ghosttyController.setTheme(Self.ghosttyTheme())
        let isDark = NSApp.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        ghosttyController.setColorScheme(isDark ? .dark : .light)
    }

    /// Releases the surface. The view itself stays in the layout so teardown
    /// never pulls a pane out from under SwiftUI mid-frame.
    func detach() {
        controller = nil
        ghosttyController = nil
    }

    // MARK: - Configuration

    private func terminalConfiguration(command: String) -> TerminalConfiguration {
        let settings = AppSettings.shared
        let family = settings.fontFamily.isEmpty
            ? TerminalFont.bundledFamily : settings.fontFamily
        return TerminalConfiguration { builder in
            builder.withFontFamily(family)
            // Keep Zshell's bundled icon font as a fallback after the selected
            // primary face. Repeated font-family entries form Ghostty's list.
            builder.withCustom("font-family", "Symbols Nerd Font Mono")
            builder.withFontSize(Float(settings.fontSize))
            // Always set explicitly: the wrapper's ConfigSource.none base
            // config injects the package default `font-thicken = true`, and
            // only a later entry in the rendered config overrides it.
            builder.withFontThicken(settings.fontThicken)
            builder.withCursorStyle(settings.cursorShape.ghosttyValue)
            builder.withCursorStyleBlink(settings.cursorBlinking)
            // Zshell's insets around the grid live inside ghostty as
            // window-padding so that window-padding-color=extend can flood
            // them with the nearest cell's background — full-screen TUIs
            // fill the surface while text keeps its breathing room (the
            // host adds a 2pt pane-background frame around the surface, so
            // the fill stops just short of the pane edges; these values plus
            // that frame put the text at least 12pt from the sides and 10pt
            // from the top/bottom). Balance splits sub-cell remainder across
            // both edges instead of leaving what looks like a reserved strip
            // below the final row. Git context is cached per terminal root so
            // tab selection no longer resizes through an intermediate toolbar
            // state and makes that balanced origin move twice.
            builder.withWindowPaddingX(10)
            builder.withWindowPaddingY(8)
            builder.withCustom("window-padding-balance", "true")
            builder.withCustom("window-padding-color", "extend")
            // Zshell owns the app-level command map. Leaving Ghostty's defaults
            // installed makes its performKeyEquivalent intercept shortcuts
            // such as Cmd-T, Cmd-N, Cmd-D, Cmd-K, and project/tab navigation
            // before SwiftUI's command menu can handle them.
            builder.withCustom("keybind", "clear")
            // Reinstall only terminal-local editing and scrolling bindings.
            // These preserve the native macOS shell experience without
            // reclaiming any shortcut owned by Zshell's command menus.
            for keybind in [
                "alt+left=esc:b",
                "alt+right=esc:f",
                "super+left=text:\\x01",
                "super+right=text:\\x05",
                "super+backspace=text:\\x15",
                "super+home=scroll_to_top",
                "super+end=scroll_to_bottom",
                "super+page_up=scroll_page_up",
                "super+page_down=scroll_page_down",
            ] {
                builder.withCustom("keybind", keybind)
            }
            builder.withCustom("command", "shell:\(command)")
            builder.withCustom("term", "xterm-256color")
            // The launch command is a `/bin/sh -c` shim, so `detect` would
            // miss the final login shell and never emit its OSC 133 prompts.
            // Prompt markers distinguish the editable command line from
            // terminal output, so clicks can move the shell cursor without
            // stealing mouse events from full-screen terminal programs.
            builder.withCustom("shell-integration", launchShellIntegration)
            builder.withCustom("cursor-click-to-move", "true")
            // The previous backend retained 500 rows. Ghostty budgets bytes
            // instead, so use a small per-surface cap with enough room for at
            // least that many normally sized rows while keeping synchronous
            // history exports bounded.
            builder.withCustom("scrollback-limit", "4194304")
            // Keep macOS text composition available by default so input
            // sources such as Polish Pro can produce Option-key characters.
            // Users who rely on terminal Meta bindings can opt back in.
            builder.withCustom(
                "macos-option-as-alt",
                settings.macosOptionAsAlt ? "true" : "false"
            )
            builder.withCustom("scrollbar", "never")
            builder.withBackgroundOpacity(backgroundOpacity)
            // Terminal-program clipboard access via OSC 52, matching the
            // Ghostty app defaults: reads prompt the user per request
            // (TerminalSession presents the confirmation sheet), writes
            // are allowed so OSC 52 copy from remote tmux/vim works, and
            // paste protection warns before pastes that look like they
            // could execute commands. Never `allow` reads without a
            // prompt — that lets any program whose output reaches the
            // terminal, including a remote SSH host, silently exfiltrate
            // the macOS clipboard through the PTY. Set explicitly so the
            // wrapper's base config can never drift them. Cmd-C/Cmd-V are
            // host-initiated and stay prompt-free (unless an unsafe paste
            // trips protection).
            builder.withCustom("clipboard-read", "ask")
            builder.withCustom("clipboard-write", "allow")
            builder.withCustom("clipboard-paste-protection", "true")
        }
    }

    /// Ghostty can only inject known shell integrations. A direct command has
    /// no interactive prompt, so it deliberately keeps injection disabled.
    private static func shellIntegration(for shellPath: String?) -> String {
        guard let shellPath else { return "none" }
        switch (shellPath as NSString).lastPathComponent {
        case "bash", "elvish", "fish", "nushell", "zsh":
            return (shellPath as NSString).lastPathComponent
        default:
            return "none"
        }
    }

    private static func ghosttyTheme() -> GhosttyTerminal.TerminalTheme {
        GhosttyTerminal.TerminalTheme(
            light: Theme.terminal(dark: false).toTerminalConfiguration(),
            dark: Theme.terminal(dark: true).toTerminalConfiguration()
        )
    }
}

// MARK: - libghostty surface callbacks

extension ZshellTerminalView: TerminalSurfaceTitleDelegate {
    func terminalDidChangeTitle(_ title: String) {
        events?.terminalDidChangeTitle(title)
    }
}

extension ZshellTerminalView: TerminalSurfacePwdDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String) {
        events?.terminalDidChangeWorkingDirectory(path)
    }
}

extension ZshellTerminalView: TerminalSurfaceGridResizeDelegate {
    func terminalDidResize(_ size: TerminalGridMetrics) {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        guard scale > 0 else { return }
        events?.terminalDidChangeCellSize(CGSize(
            width: CGFloat(size.cellWidthPixels) / scale,
            height: CGFloat(size.cellHeightPixels) / scale
        ))
    }
}

extension ZshellTerminalView: TerminalSurfaceBellDelegate {
    func terminalDidRingBell() {
        events?.terminalDidRingBell()
    }
}

extension ZshellTerminalView: TerminalSurfaceCloseDelegate {
    func terminalDidClose(processAlive: Bool) {
        events?.terminalDidClose(processAlive: processAlive)
    }
}

extension ZshellTerminalView: TerminalSurfaceDesktopNotificationDelegate {
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        events?.terminalDidRequestDesktopNotification(title: title, body: body)
    }
}

extension ZshellTerminalView: TerminalSurfaceProgressReportDelegate {
    /// OSC 9;4 draws this surface's own progress bar, so it never has to
    /// travel out to the session and back.
    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        applyProgressReport(state: state, percent: percent)
    }
}

extension ZshellTerminalView: TerminalSurfaceCommandFinishedDelegate {
    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        events?.terminalDidReportShellIntegration(
            .commandFinished(exitCode: exitCode, durationNanos: durationNanos)
        )
    }
}

extension ZshellTerminalView: TerminalSurfaceOpenURLDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        // A history export borrows this callback as its synchronous return
        // channel for a file path; that one is not a URL to open.
        if consumeHistoryExportURL(url, kind: kind) { return }
        events?.terminalDidRequestOpenURL(url)
    }
}

extension ZshellTerminalView: TerminalSurfaceHoverLinkDelegate {
    func terminalDidUpdateHoverLink(_ url: String?) {
        hoveredLink = url
    }
}

extension ZshellTerminalView: TerminalSurfaceScrollbarDelegate {
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        let position = TerminalScrollPosition(
            totalRows: scrollbar.total,
            viewportRows: scrollbar.len,
            topRow: scrollbar.offset
        )
        lastScroll = position
        events?.terminalDidScroll(position)
    }
}

extension ZshellTerminalView: TerminalSurfaceSearchDelegate {
    func terminalDidStartSearch(needle: String) {
        events?.terminalDidBeginFind(needle: needle)
    }

    func terminalDidEndSearch() {
        events?.terminalDidEndFind()
    }

    func terminalDidUpdateSearchTotal(_ total: Int?) {
        events?.terminalDidUpdateFindTotal(total)
    }

    func terminalDidUpdateSearchSelected(_ selected: Int?) {
        events?.terminalDidUpdateFindSelected(selected)
    }
}

extension ZshellTerminalView: TerminalSurfaceClipboardConfirmationDelegate {
    func terminalDidRequestClipboardConfirmation(
        _ request: TerminalClipboardConfirmationRequest
    ) {
        let kind: TerminalClipboardRequest.Kind
        switch request.kind {
        case .unsafePaste: kind = .unsafePaste
        case .osc52Read: kind = .programRead
        }
        events?.terminalDidRequestClipboardConfirmation(
            TerminalClipboardRequest(kind: kind, contents: request.contents) { approved in
                if approved {
                    request.approve()
                } else {
                    request.deny()
                }
            }
        )
    }
}
