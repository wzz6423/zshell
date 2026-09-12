//
//  TerminalSession.swift
//  zshell
//

import AppKit
import Combine
import Darwin
import Foundation

/// One long-lived terminal process rendered by one terminal surface. Normally
/// that process is the user's login shell; a CLI-created project can instead
/// exec an explicit argv directly. SwiftUI only reparents the same surface, so
/// PTY state, selection, and scrollback survive tab and split-layout changes.
///
/// Which emulator draws that surface is `TerminalBackend`'s business: this
/// type talks to ``TerminalBackendSurface`` and hears back through
/// ``TerminalBackendEvents``, and names no emulator's types itself.
@MainActor
final class TerminalSession: NSObject, nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id: UUID

    @Published var title: String
    @Published var workingDirectory: String?
    @Published var hasExited = false
    @Published private(set) var commandLifecycle = TerminalCommandLifecycle()
    @Published private(set) var terminalCellSize: CGSize?
    /// Recognized coding agent occupying this terminal, if any. The monitor
    /// reconciles foreground process identity with explicit lifecycle events.
    @Published var agentStatus: ZshellAgentStatus?

    /// The emulator driving this session. Fixed for the session's lifetime —
    /// changing the setting only affects terminals opened afterwards.
    let backend: TerminalBackend
    let surface: any TerminalBackendSurface
    let overlayScrollbar = OverlayScrollbarView()
    /// Find-in-terminal state for this session's pane (⌘F).
    let find: TerminalFind
    var onExited: ((TerminalSession) -> Void)?

    /// Identity of the manager currently allowed to host this surface. Moving a
    /// tab updates it synchronously so stale parking/visible hosts in the source
    /// window cannot reparent the terminal after destination adoption.
    private(set) var hostManagerID: ObjectIdentifier?

    private static let persistedHistoryLineLimit = 500

    private let shellPath: String
    private let launchWorkingDirectory: String
    private let launchDirectoryURL: URL?
    private let shellPidFileURL: URL?
    private var cachedShellPid: pid_t?
    private var lastHistorySnapshot: String?
    private var isTerminating = false
    private var commandExecutionStartedAtNanos: UInt64?
    /// Alternate-screen transcript paging must begin at the live prompt, never
    /// from text the user has scrolled back to inspect.
    var terminalIsAtLiveBottom = true
    let agentObservation = ZshellAgentObservationState()
    /// Typed-ahead prompts for this session (the ⌘⇧M pane-bottom bar).
    /// In-memory by design — see ``TerminalPromptQueue``.
    let promptQueue = TerminalPromptQueue()
    /// The queue's bar, session-owned like `overlayScrollbar` so its open
    /// state and contents survive a pane being parked and remounted.
    let promptQueueBar = PromptQueueBarView()
    /// Scheduled auto-dispatch for `promptQueue`. Scheduling and the
    /// readiness gate live in TerminalPromptQueue.swift.
    var promptQueueDispatchTask: Task<Void, Never>?

    init(
        initialDirectory: String? = nil,
        restoredHistory: String? = nil,
        commandArguments: [String]? = nil,
        environmentPath: String? = nil,
        launchSettings: TerminalLaunchSettings = .init()
    ) {
        let sessionID = UUID()
        let directCommand = commandArguments.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.configuredStartupCommand()
        let shellPath = directCommand?.first ?? Self.loginShell()
        let directory = Self.validWorkingDirectory(initialDirectory)
        let backend = AppSettings.shared.terminalBackend
        let artifacts = Self.makeLaunchArtifacts(
            restoredHistory: restoredHistory,
            backend: backend,
            shellPath: directCommand == nil ? shellPath : nil
        )
        let script = Self.makeLaunchScript(
            backend: backend,
            shellPath: shellPath,
            commandArguments: directCommand,
            initializationCommand: directCommand == nil
                ? launchSettings.initializationCommand : nil,
            pidFileURL: artifacts.pidFileURL,
            replayFileURL: artifacts.replayFileURL,
            shellIntegrationDirectoryURL: artifacts.shellIntegrationDirectoryURL
        )
        let launch = TerminalLaunch(
            program: "/bin/sh",
            arguments: ["-c", script],
            commandLine: "/bin/sh -c \(Self.shellQuote(script))",
            interactiveShell: directCommand == nil ? shellPath : nil,
            workingDirectory: directory,
            environment: Self.surfaceEnvironment(
                pathOverride: environmentPath,
                configuredEnvironment: launchSettings.environment,
                sessionID: sessionID
            )
        )

        id = sessionID
        self.shellPath = shellPath
        self.backend = backend
        launchWorkingDirectory = directory
        launchDirectoryURL = artifacts.directoryURL
        shellPidFileURL = artifacts.pidFileURL
        title = (shellPath as NSString).lastPathComponent
        agentStatus = nil

        let surface = Self.makeSurface(backend: backend, launch: launch)
        self.surface = surface
        find = TerminalFind(surface: surface)
        lastHistorySnapshot = restoredHistory
        super.init()

        surface.events = self
        installOverlayScrollbar()
        promptQueueBar.attach(queue: promptQueue, session: self)
        applyTheme()
        AgentAutomationMonitor.shared.register(self)
    }

    deinit {
        if let launchDirectoryURL {
            try? FileManager.default.removeItem(at: launchDirectoryURL)
        }
    }

    /// `makeSurface` returns nil only for a backend this build has no surface
    /// for, and `AppSettings` refuses to store one — so this is belt and
    /// braces, preferring a working terminal over an empty pane.
    private static func makeSurface(
        backend: TerminalBackend, launch: TerminalLaunch
    ) -> any TerminalBackendSurface {
        if let surface = backend.makeSurface(launch: launch) { return surface }
        NSLog("zshell: no surface for terminal backend \(backend.rawValue)")
        return ZshellTerminalView(launch: launch)
    }

    private func installOverlayScrollbar() {
        overlayScrollbar.alphaValue = 0
        overlayScrollbar.onScroll = { [weak self] position in
            self?.surface.scroll(toFraction: position)
        }
    }

    /// Changes which window may host this session without restarting or
    /// replacing its backend surface.
    func transferHost(to manager: TerminalManager) {
        hostManagerID = ObjectIdentifier(manager)
    }

    func belongs(to manager: TerminalManager) -> Bool {
        hostManagerID == ObjectIdentifier(manager)
    }

    /// Reconfigures the surface in place when appearance or terminal settings
    /// change. A caller may supply an override for surfaces, such as the quick
    /// terminal, whose alpha is not owned by the main-window setting.
    func applyTheme(backgroundOpacity: CGFloat? = nil) {
        surface.setBackgroundOpacity(
            backgroundOpacity
                ?? CGFloat(AppSettings.shared.effectiveTerminalBackgroundOpacity)
        )
        surface.applyAppearance()
    }

    /// Stops the whole PTY job before releasing the surface. The backend's
    /// teardown owns the final reap; sending HUP first gives shells the same
    /// close signal they received before the backend migration.
    func terminate() {
        guard !hasExited, !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: true, notifyExit: false)
    }

    /// Keeps the session and surface alive until the child has either exited
    /// or been force-stopped. Detaching first can make a backend wait
    /// synchronously for a process that ignored SIGHUP.
    private func beginTeardown(processAlive: Bool, notifyExit: Bool) {
        // TerminalHostView normally clears these while dismantling, but close
        // teardown must not depend on a later SwiftUI reconciliation pass.
        // These callbacks originate on PaneView and capture this session.
        surface.setSurfaceVisible(false)
        surface.onBecomeFirstResponder = nil
        surface.splitTarget.onSplit = nil
        surface.splitTarget.onNewBrowserTab = nil
        surface.splitTarget.onNewBrowserPane = nil
        surface.splitTarget.onNewFileTab = nil
        surface.splitTarget.onNewFilePane = nil

        if processAlive {
            _ = shellPid // Cache it before `hasExited` changes.
            signalTerminalJob(SIGHUP)
        }

        Task { @MainActor [self] in
            if processAlive {
                // Give well-behaved shells a moment to unwind, then guarantee
                // surface teardown cannot wait indefinitely.
                try? await Task.sleep(for: .milliseconds(120))
                signalTerminalJob(SIGKILL)
            } else {
                // Avoid freeing the surface reentrantly from the backend's
                // process-close callback.
                await Task.yield()
            }
            surface.detach()
            hasExited = true
            removeLaunchArtifacts()
            if notifyExit { onExited?(self) }
        }
    }

    private func signalTerminalJob(_ signal: Int32) {
        var pids = Set<pid_t>()
        if let shellPid { pids.insert(shellPid) }
        if let foreground = surface.foregroundPid, foreground > 0 {
            pids.insert(foreground)
        }
        for pid in pids where pid > 1 {
            // Interactive shells and their foreground jobs normally lead
            // distinct process groups. Signal the group, then the leader as a
            // fallback for an unusual launch configuration.
            _ = Darwin.kill(-pid, signal)
            _ = Darwin.kill(pid, signal)
        }
    }

    private func removeLaunchArtifacts() {
        ZshellCLIService.shared.revokeTerminal(id: id)
        guard let launchDirectoryURL else { return }
        try? FileManager.default.removeItem(at: launchDirectoryURL)
    }

    /// Short label for the sidebar: the tail of the current directory, if known.
    var directoryLabel: String? {
        guard let dir = workingDirectory else { return nil }
        let path = URL(string: dir)?.path ?? dir
        let tail = (path as NSString).lastPathComponent
        return tail.isEmpty ? nil : tail
    }

    /// Best-effort live shell directory: OSC 7 first, kernel process metadata
    /// second, then the directory used to launch this session.
    var currentDirectoryPath: String {
        if let dir = workingDirectory {
            if let url = URL(string: dir), url.isFileURL { return url.path }
            if dir.hasPrefix("/") { return dir }
        }
        if let shellPid, let path = processWorkingDirectory(pid: shellPid) {
            return path
        }
        return launchWorkingDirectory
    }

    /// Working directory of the terminal's foreground job, when that job is
    /// something other than the shell itself. Coding agents change their own
    /// process directory when they move to another checkout — Claude Code's
    /// worktree switch is a `chdir` inside the running `claude` process — and
    /// the shell never moves, so no OSC 7 arrives and `currentDirectoryPath`
    /// keeps describing the old tree. This is deliberately a separate fact:
    /// `currentDirectoryPath` must stay true to the shell.
    var foregroundDirectoryPath: String? {
        guard let foreground = surface.foregroundPid, foreground > 0,
              foreground != shellPid
        else { return nil }
        return processWorkingDirectory(pid: foreground)
    }

    func sendCommand(_ text: String) {
        surface.sendText(text)
    }

    func sendEnter() {
        surface.sendEnter()
    }

    /// Clears the emulator's visible screen and scrollback, then asks the
    /// foreground shell to repaint its prompt at the top.
    func clear() {
        surface.clearScreen()
    }

    /// Styled VT snapshot used by the existing sidecar history store. A
    /// scrollback/PID heuristic keeps a full-screen alternate buffer from
    /// replacing the last saved shell scrollback in normal shell/TUI use.
    func serializedHistory(captureLive: Bool) -> String? {
        guard AppSettings.shared.restoreTerminalHistory else { return nil }
        guard captureLive else { return lastHistorySnapshot }

        let rootShellIsForeground = shellPid != nil
            && surface.foregroundPid == shellPid
        if !rootShellIsForeground,
           !TerminalHistorySerializer.hasPrimaryScrollback(surface) {
            // A primary screen with no rows above the viewport and an
            // alternate screen both have no scrollback export. The root shell
            // is foreground only in the former case; a TUI owns its own
            // foreground process group in the latter.
            return lastHistorySnapshot
        }
        switch TerminalHistorySerializer.capture(
            from: surface, maxLines: Self.persistedHistoryLineLimit
        ) {
        case .captured(let snapshot):
            lastHistorySnapshot = snapshot
            return snapshot
        case .failed:
            return lastHistorySnapshot
        }
    }

    var shellName: String {
        (shellPath as NSString).lastPathComponent
    }

    /// PID of the root terminal process. The launch shim records its own PID
    /// before `exec`, so this remains stable while a shell's foreground PID
    /// moves to child jobs and back.
    var shellPid: pid_t? {
        if let cachedShellPid, cachedShellPid > 0 { return cachedShellPid }
        guard !hasExited, let shellPidFileURL,
              let text = try? String(contentsOf: shellPidFileURL, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else { return nil }
        cachedShellPid = value
        return value
    }

    // MARK: - Launch

    private static func surfaceEnvironment(
        pathOverride: String?,
        configuredEnvironment: [String: String],
        sessionID: UUID
    ) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        ]
        environment.merge(
            ZshellCLIService.shared.terminalEnvironment(for: sessionID),
            uniquingKeysWith: { _, cliValue in cliValue }
        )
        environment.merge(
            configuredEnvironment.filter {
                !TerminalLaunchSettings.isProtectedEnvironmentVariable($0.key)
            },
            uniquingKeysWith: { _, configuredValue in configuredValue }
        )
        if let pathOverride, !pathOverride.isEmpty {
            environment["PATH"] = pathOverride
        }
        // Locale belongs to the user's shell environment. Zshell's app language
        // must never synthesize or override LANG/LC_* for terminal processes.
        return environment
    }

    private struct LaunchArtifacts {
        let directoryURL: URL?
        let pidFileURL: URL?
        let replayFileURL: URL?
        let shellIntegrationDirectoryURL: URL?
    }

    private static func makeLaunchArtifacts(
        restoredHistory: String?,
        backend: TerminalBackend,
        shellPath: String?
    ) -> LaunchArtifacts {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("zshell-terminal-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let pidFile = directory.appendingPathComponent("shell.pid")
            var replayFile: URL?
            if AppSettings.shared.restoreTerminalHistory,
               let restoredHistory,
               !restoredHistory.isEmpty {
                let file = directory.appendingPathComponent("history.vt")
                let separator = restoredHistory.hasSuffix("\n") ? "" : "\r\n"
                let contents = restoredHistory + separator
                    + TerminalHistorySerializer.restoredBanner() + "\r\n"
                try Data(contents.utf8).write(to: file, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path
                )
                replayFile = file
            }
            let shellIntegrationDirectory = try makeShellIntegrationArtifacts(
                in: directory,
                shellPath: shellPath
            )
            return LaunchArtifacts(
                directoryURL: directory,
                pidFileURL: pidFile,
                replayFileURL: replayFile,
                shellIntegrationDirectoryURL: shellIntegrationDirectory
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            NSLog("zshell: failed to prepare terminal launch files: \(error)")
            return LaunchArtifacts(
                directoryURL: nil,
                pidFileURL: nil,
                replayFileURL: nil,
                shellIntegrationDirectoryURL: nil
            )
        }
    }

    /// The `sh` script every pane starts with: record the process PID, replay
    /// any restored scrollback, advertise the emulator, then become either the
    /// requested argv or the user's login shell.
    private static func makeLaunchScript(
        backend: TerminalBackend,
        shellPath: String,
        commandArguments: [String]?,
        initializationCommand: String?,
        pidFileURL: URL?,
        replayFileURL: URL?,
        shellIntegrationDirectoryURL: URL?
    ) -> String {
        var commands: [String] = []
        if let pidFileURL {
            // The PID file is the only thing this script creates, so the
            // tightened mask stays inside a subshell: `umask` outlives the
            // `exec` below, and a terminal that leaves the user's shell at 077
            // silently makes every file they create private. `$$` keeps
            // expanding to this shell's PID inside the subshell — the same PID
            // `exec` hands to the shell itself.
            commands.append(
                "(umask 077; printf '%s\\n' \"$$\" > \(shellQuote(pidFileURL.path)))"
            )
        }
        if let replayFileURL {
            let path = shellQuote(replayFileURL.path)
            commands.append("if [ -r \(path) ]; then /bin/cat \(path); /bin/rm -f \(path); fi")
        }
        // ZSHELL_TERM exposes the actual surface. TERM_PROGRAM remains a
        // capability hint so tools select protocols Zshell can actually render.
        commands.append("export ZSHELL_TERM=\(shellQuote(backend.environmentName))")
        let termProgram = backend.termProgram
        commands.append("export TERM_PROGRAM=\(shellQuote(termProgram.name))")
        if !termProgram.version.isEmpty {
            commands.append(
                "export TERM_PROGRAM_VERSION=\(shellQuote(termProgram.version))"
            )
        } else {
            commands.append("unset TERM_PROGRAM_VERSION")
        }
        if let commandArguments {
            let argv = commandArguments.map(shellQuote).joined(separator: " ")
            // `env` resolves argv[0] against the caller's PATH. Every argument
            // is quoted independently, so no command text is reparsed or
            // expanded by the launch shim.
            commands.append("exec /usr/bin/env -- \(argv)")
        } else {
            let initialization = initializationCommand?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let command = initialization.flatMap { $0.isEmpty ? nil : $0 }
            if let shellIntegrationDirectoryURL {
                let path = shellQuote(shellIntegrationDirectoryURL.path)
                commands.append(
                    "ZSHELL_ORIGINAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"; "
                        + "export ZSHELL_ORIGINAL_ZDOTDIR; "
                        + "export ZDOTDIR=\(path); "
                        + "export ZSHELL_INIT_COMMAND=\(shellQuote(command ?? "")); "
                        + "exec \(shellQuote(shellPath)) -l"
                )
            } else if let command {
                commands.append(
                    "exec \(shellQuote(shellPath)) -l -c "
                        + shellQuote(initializationScript(command: command, shellPath: shellPath))
                )
            } else {
                commands.append("exec \(shellQuote(shellPath)) -l")
            }
        }
        // Ghostty's macOS launcher prepends `exec -l` to a shell command.
        // Keeping the setup as one compound command means `exec -l` does not
        // stop after the first shell builtin.
        return commands.joined(separator: "; ")
    }

    /// Zshell launches panes through `/bin/sh -c`, so the proxy preserves the
    /// user's regular zsh startup files and adds the OSC prompt markers both
    /// terminal backends use for prompt-local mouse editing. It lives in the
    /// session's 0700 temp directory.
    private static func makeShellIntegrationArtifacts(
        in directory: URL,
        shellPath: String?
    ) throws -> URL? {
        guard let shellPath,
              (shellPath as NSString).lastPathComponent == "zsh"
        else { return nil }

        let integrationDirectory = directory
            .appendingPathComponent("zsh-integration", isDirectory: true)
        try FileManager.default.createDirectory(
            at: integrationDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let selectionStatePath = shellQuote(directory.appendingPathComponent("prompt-selection.pid").path)
        var files = [
            ".zshenv": """
            [[ -r \"$ZSHELL_ORIGINAL_ZDOTDIR/.zshenv\" ]] && source \"$ZSHELL_ORIGINAL_ZDOTDIR/.zshenv\"
            """,
            ".zprofile": """
            [[ -r \"$ZSHELL_ORIGINAL_ZDOTDIR/.zprofile\" ]] && source \"$ZSHELL_ORIGINAL_ZDOTDIR/.zprofile\"
            """,
            ".zshrc": """
            # /etc/zshrc and the user's own config both derive paths from ZDOTDIR --
            # HISTFILE, compinit's dump, plugin caches -- and ours points at a
            # per-session temp directory that is deleted with the session. Restore
            # the real one before any of that is read, and correct what /etc/zshrc
            # has already derived from it: otherwise every pane opens on an empty
            # history, saves none of its own, and rebuilds .zcompdump from scratch.
            if [[ -n \"$ZSHELL_ORIGINAL_ZDOTDIR\" ]]; then
              [[ \"$HISTFILE\" == \"$ZDOTDIR\"/* ]] && HISTFILE=\"$ZSHELL_ORIGINAL_ZDOTDIR/.zsh_history\"
              export ZDOTDIR=\"$ZSHELL_ORIGINAL_ZDOTDIR\"
            fi
            [[ -r \"$ZSHELL_ORIGINAL_ZDOTDIR/.zshrc\" ]] && source \"$ZSHELL_ORIGINAL_ZDOTDIR/.zshrc\"
            autoload -Uz add-zsh-hook add-zle-hook-widget
            _zshell_prompt_marker() {
              _zshell_selection_active=0
              REGION_ACTIVE=0
              builtin print -n $'\\e]133;A;cl=line\\a'
            }
            _zshell_selection_active=0
            _zshell_begin_selection() {
              MARK=$CURSOR
              REGION_ACTIVE=1
              _zshell_selection_active=1
            }
            _zshell_activate_selection() {
              if (( _zshell_selection_active )); then
                REGION_ACTIVE=1
              fi
            }
            # A mouse selection stays armed until a wrapped widget consumes it, so a key
            # that only moves the cursor would leave kill-region covering text the pane has
            # already stopped drawing as selected. The pane disarms it here first.
            _zshell_cancel_selection() {
              _zshell_selection_active=0
              REGION_ACTIVE=0
            }
            # Succeeds only when a region really went away. That keystroke is then spent on
            # the kill, so a wrapped delete widget must not also run -- otherwise Backspace
            # removes the selection plus one more character.
            _zshell_kill_selection() {
              (( _zshell_selection_active )) || return 1
              if (( MARK == CURSOR )); then
                _zshell_selection_active=0
                REGION_ACTIVE=0
                return 1
              fi
              zle kill-region
              local _zshell_kill_status=$?
              _zshell_selection_active=0
              REGION_ACTIVE=0
              return $_zshell_kill_status
            }
            # Wrap on top of whatever is already bound instead of replacing it: `zle -A`
            # snapshots the live widget (builtin or plugin) and $WIDGET carries the bound
            # name, so one handler pair serves every widget and zsh-autosuggestions or
            # zsh-syntax-highlighting keep running.
            _zshell_replace_widget() {
              _zshell_kill_selection
              zle "_zshell_saved_$WIDGET" -- "$@"
            }
            _zshell_consume_widget() {
              _zshell_kill_selection && return
              zle "_zshell_saved_$WIDGET" -- "$@"
            }
            _zshell_wrap_widget() {
              zle -A "$1" "_zshell_saved_$1" 2>/dev/null || return
              zle -N "$1" "$2"
            }
            _zshell_wrap_widget self-insert _zshell_replace_widget
            _zshell_wrap_widget bracketed-paste _zshell_replace_widget
            # Backspace and forward delete reach different widgets per keymap and per
            # framework, so cover every spelling a single keypress can land on.
            _zshell_delete_widgets=(
              backward-delete-char vi-backward-delete-char
              delete-char vi-delete-char delete-char-or-list
            )
            for _zshell_widget in $_zshell_delete_widgets; do
              _zshell_wrap_widget $_zshell_widget _zshell_consume_widget
            done
            unset _zshell_widget _zshell_delete_widgets
            zle -N _zshell_begin_selection
            zle -N _zshell_activate_selection
            zle -N _zshell_cancel_selection
            # Config reloads may rebuild the keymaps. Reinstall our private bindings
            # before advertising readiness; a nested or exec'd zsh has no such widgets.
            _zshell_selection_ready() {
              _zshell_selection_finished
              local _zshell_keymap
              for _zshell_keymap in emacs viins vicmd "$KEYMAP"; do
                bindkey -M "$_zshell_keymap" $'\\x1f' _zshell_begin_selection || return
                bindkey -M "$_zshell_keymap" $'\\x1e' _zshell_activate_selection || return
                bindkey -M "$_zshell_keymap" $'\\e[27;2;27~' _zshell_cancel_selection || return
              done
              builtin print -r -- "$$" >| \(selectionStatePath)
            }
            _zshell_selection_finished() {
              builtin print -rn -- '' >| \(selectionStatePath)
            }
            add-zsh-hook precmd _zshell_prompt_marker
            _zshell_line_init() {
              _zshell_selection_active=0
              REGION_ACTIVE=0
              _zshell_selection_ready
              builtin print -n $'\\e]133;P;k=i\\a\\e]133;B\\a'
            }
            add-zle-hook-widget line-init _zshell_line_init
            add-zle-hook-widget line-finish _zshell_selection_finished
            add-zle-hook-widget keymap-select _zshell_selection_ready
            _zshell_insert_newline() { LBUFFER+=$'\\n'; }
            zle -N _zshell_insert_newline
            for _zshell_keymap in emacs viins; do
              bindkey -M "$_zshell_keymap" $'\\e[27;2;13~' _zshell_insert_newline
              bindkey -M "$_zshell_keymap" $'\\e[13;2u' _zshell_insert_newline
              bindkey -M "$_zshell_keymap" $'\\e\\r' _zshell_insert_newline
            done
            unset _zshell_keymap
            """,
            ".zlogin": """
            [[ -r \"$ZSHELL_ORIGINAL_ZDOTDIR/.zlogin\" ]] && source \"$ZSHELL_ORIGINAL_ZDOTDIR/.zlogin\"
            if [[ -n \"$ZSHELL_INIT_COMMAND\" ]]; then
              eval -- \"$ZSHELL_INIT_COMMAND\" || builtin print -u2 -- \"zshell: initialization command failed ($?)\"
              unset ZSHELL_INIT_COMMAND
            fi
            """,
        ]
        // Command-completion notifications ride the same zsh-only shim: bash
        // and fish never see ZDOTDIR, so this script is the only place the
        // app can hear a command's start and exit. Both opt-in settings are
        // baked into the text here; a running shell never re-reads them, so
        // changes reach terminals opened afterwards.
        if AppSettings.shared.notifyFinishSeconds > 0 || AppSettings.shared.notifyOnError {
            files[".zshrc"]? += """


            # Command-completion notifications. The shim only ever reaches
            # Zshell's own zsh panes -- other shells get no shim, and a nested
            # zsh reads the user's own config -- so the OSC 777 printed here
            # is consumed by the app that injected this script and never
            # reaches a third-party terminal. The threshold and error switch
            # are baked in above. zsh/datetime supplies the wall-clock start
            # stamp; on a zsh too old to provide one the feature silently
            # stays off.
            _zshell_notify_seconds=\(AppSettings.shared.notifyFinishSeconds)
            _zshell_notify_on_error=\(AppSettings.shared.notifyOnError ? 1 : 0)
            _zshell_notify_stamp=0
            _zshell_notify_word=''
            zmodload -i zsh/datetime 2>/dev/null
            if (( $+EPOCHSECONDS )); then
              _zshell_notify_preexec() {
                local _zshell_notify_prev=$?
                _zshell_notify_stamp=$EPOCHSECONDS
                _zshell_notify_word=${${=1}[1]}
                return $_zshell_notify_prev
              }
              # Runs ahead of every other precmd hook: prompt frameworks
              # install their own precmd work -- git status, kubectl context
              # -- whose commands would overwrite `$?` before a hook appended
              # after theirs could read it, so the command's own exit status
              # must be captured first. Returning it keeps `$?` for the hooks
              # behind exactly as if this hook were absent.
              _zshell_notify_precmd() {
                local _zshell_notify_status=$?
                if (( _zshell_notify_stamp )); then
                  local _zshell_notify_elapsed=$(( EPOCHSECONDS - _zshell_notify_stamp ))
                  _zshell_notify_stamp=0
                  local _zshell_notify_fire=0
                  if (( _zshell_notify_seconds > 0 && _zshell_notify_elapsed >= _zshell_notify_seconds )); then
                    _zshell_notify_fire=1
                  fi
                  if (( _zshell_notify_on_error && _zshell_notify_status != 0 )); then
                    _zshell_notify_fire=1
                  fi
                  if (( _zshell_notify_fire )); then
                    # The command name becomes notification text: strip
                    # control characters, which the notification parsers
                    # reject the whole message over, and `;`, which would
                    # forge the title/body field split; cap the rest so one
                    # pathological word cannot flood a banner. Nothing
                    # presentable left means nothing to announce.
                    local _zshell_notify_name=${_zshell_notify_word//[[:cntrl:];]/}
                    _zshell_notify_name=${_zshell_notify_name[1,64]}
                    if [[ -n $_zshell_notify_name ]]; then
                      local _zshell_notify_outcome=finished
                      (( _zshell_notify_status != 0 )) && _zshell_notify_outcome=failed
                      printf '\\e]777;notify;%s;%s\\e\\\\' "$_zshell_notify_name $_zshell_notify_outcome" "$_zshell_notify_name $_zshell_notify_outcome — ${_zshell_notify_elapsed}s, exit $_zshell_notify_status"
                    fi
                  fi
                fi
                return $_zshell_notify_status
              }
              add-zsh-hook preexec _zshell_notify_preexec
              # add-zsh-hook only appends, and the last precmd hook sees
              # whatever the ones before it left in `$?` -- that ordering is
              # the whole reason this hook is prepended by hand.
              if [[ -z "${precmd_functions[(r)_zshell_notify_precmd]}" ]]; then
                precmd_functions=(_zshell_notify_precmd "${precmd_functions[@]}")
              fi
            fi
            """
        }
        for (name, contents) in files {
            let file = integrationDirectory.appendingPathComponent(name)
            try Data((contents + "\n").utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path
            )
        }
        return integrationDirectory
    }

    private static func initializationScript(command: String, shellPath: String) -> String {
        let quotedShell = shellQuote(shellPath)
        return "\(command) || printf 'zshell: initialization command failed (%s)\\n' \"$?\" >&2; "
            + "exec \(quotedShell) -l"
    }

    /// Single-quote shell escaping. Internal because Quick Launch embeds
    /// user-host strings inside its own launch script.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validWorkingDirectory(_ requested: String?) -> String {
        var isDirectory: ObjCBool = false
        if let requested,
           FileManager.default.fileExists(atPath: requested, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return requested
        }
        return NSHomeDirectory()
    }

    /// The configured argv is read once when a pane is created. CLI launches
    /// bypass this helper, so an explicit CLI argv still wins for its terminal.
    private static func configuredStartupCommand() -> [String]? {
        let settings = AppSettings.shared
        switch TerminalStartupCommand.resolve(
            program: settings.terminalStartupProgram,
            arguments: settings.terminalStartupArguments
        ) {
        case .success(let command):
            return command?.argv
        case .failure:
            return nil
        }
    }

    /// Internal so Quick Launch entries build their launch argv around the
    /// same shell a plain session would get.
    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

// MARK: - Terminal surface callbacks

extension TerminalSession: TerminalBackendEvents {
    var terminalPromptSelectionIsReady: Bool {
        guard !hasExited, let launchDirectoryURL, let foregroundPID = surface.foregroundPid,
              let value = try? String(
                contentsOf: launchDirectoryURL.appendingPathComponent("prompt-selection.pid"),
                encoding: .utf8
              ),
              let readyPID = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return readyPID > 0 && readyPID == foregroundPID
    }

    func terminalDidChangeTitle(_ title: String) {
        guard !title.isEmpty else { return }
        self.title = title
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        workingDirectory = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).absoluteString : path
    }

    func terminalDidChangeCellSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0,
              terminalCellSize != size else { return }
        terminalCellSize = size
    }

    func terminalDidRingBell() {
        let announcement = String(localized: "Terminal bell")
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.low.rawValue,
            ]
        )

        guard AppSettings.shared.terminalBell else { return }
        NSSound.beep()
        // A miniaturized key window keeps its first responder, so the focus
        // check alone still reads "focused" while the user cannot see the
        // surface at all — minimized terminals need the notification too.
        let windowMiniaturized = surface.window?.isMiniaturized == true
        guard !surface.hasEffectiveTerminalFocus || windowMiniaturized else { return }
        TerminalNotificationService.shared.post(
            message: announcement,
            sessionID: id
        )
        if !NSApp.isActive || windowMiniaturized {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent) {
        var lifecycle = commandLifecycle
        switch event {
        case .promptStart:
            lifecycle.phase = .prompt
            // The Alacritty path: the zsh shim marks every redrawn prompt.
            promptQueueDidObservePromptReturn()
        case .commandStart:
            lifecycle.phase = .input
        case .commandExecuting:
            lifecycle.phase = .executing
            commandExecutionStartedAtNanos = DispatchTime.now().uptimeNanoseconds
        case let .commandFinished(exitCode, reportedDuration):
            let measuredDuration = commandExecutionStartedAtNanos.flatMap { started in
                let now = DispatchTime.now().uptimeNanoseconds
                return now >= started ? now - started : nil
            }
            lifecycle.phase = .idle
            lifecycle.lastExitCode = exitCode
            lifecycle.lastDurationNanos = reportedDuration ?? measuredDuration
            lifecycle.completionSequence &+= 1
            commandExecutionStartedAtNanos = nil
            // The libghostty path: the shell integration's completed-command
            // report is the one "back at the prompt" event it exposes.
            promptQueueDidObservePromptReturn()
        }
        commandLifecycle = lifecycle
    }

    func terminalDidClose(processAlive: Bool) {
        guard !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: processAlive, notifyExit: true)
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        let message = body.isEmpty ? title : body
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        TerminalNotificationService.shared.post(message: message, sessionID: id)
    }

    func terminalDidRequestOpenURL(_ value: String) {
        guard let target = terminalLinkTarget(for: value) else { return }
        switch target {
        case .file(let fileURL):
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        case .url(let url):
            NSWorkspace.shared.open(url)
        }
    }

    /// Classifies a detected terminal link only after proving a local path
    /// exists or a non-file URL has a scheme. Context menus and Command-click
    /// use this same answer, so neither offers an action it cannot perform.
    func terminalLinkTarget(for value: String) -> TerminalLinkTarget? {
        if let fileURL = existingFileURL(from: value) {
            return .file(fileURL)
        }
        guard let url = URL(string: value),
              url.scheme != nil,
              !url.isFileURL
        else { return nil }
        return .url(url)
    }

    /// Resolves terminal links the way the shell would: `file:` URLs are
    /// already absolute, `~` belongs to the current user, and other paths are
    /// relative to this pane's live working directory. Diagnostics commonly
    /// append `:line[:column]`, so try the literal path before peeling those
    /// numeric locations off.
    private func existingFileURL(from value: String) -> URL? {
        let candidate: URL
        if let url = URL(string: value), url.scheme != nil {
            guard url.isFileURL else { return nil }
            candidate = url
        } else {
            let decoded = value.removingPercentEncoding ?? value
            let expanded = (decoded as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                candidate = URL(fileURLWithPath: expanded)
            } else {
                let basePath = foregroundDirectoryPath ?? currentDirectoryPath
                candidate = URL(
                    fileURLWithPath: expanded,
                    relativeTo: URL(fileURLWithPath: basePath, isDirectory: true)
                )
            }
        }

        var url = candidate.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            let strippedPath = url.path.replacingOccurrences(
                of: #":\d+$"#,
                with: "",
                options: .regularExpression
            )
            guard strippedPath != url.path else { return nil }
            url = URL(fileURLWithPath: strippedPath).standardizedFileURL
        }
    }

    func terminalDidScroll(_ position: TerminalScrollPosition) {
        terminalIsAtLiveBottom = position.position >= 0.999
        overlayScrollbar.update(
            position: position.position,
            proportion: position.proportion,
            active: position.isScrollable
        )
    }

    func terminalDidBeginFind(needle: String) {
        find.started(needle: needle)
    }

    func terminalDidEndFind() {
        find.ended()
    }

    func terminalDidUpdateFindTotal(_ total: Int?) {
        find.update(total: total)
    }

    func terminalDidUpdateFindSelected(_ selected: Int?) {
        find.update(selected: selected)
    }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest) {
        guard let window = surface.window else {
            request.deny()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request.kind {
        case .unsafePaste:
            alert.messageText = String(localized: "Warning: Potentially Unsafe Paste")
            alert.informativeText =
                String(localized: "Pasting this text to the terminal may be dangerous because it looks like one or more commands may execute.")
        case .programRead:
            alert.messageText = String(localized: "Authorize Clipboard Access")
            alert.informativeText =
                String(localized: "A program is attempting to read from the clipboard. The current clipboard contents are shown below.")
        }
        alert.accessoryView = Self.clipboardPreview(request.contents)
        alert.addButton(withTitle: request.kind == .unsafePaste
            ? String(localized: "Paste")
            : String(localized: "Allow"))
        let cancel = alert.addButton(
            withTitle: request.kind == .unsafePaste
                ? String(localized: "Cancel")
                : String(localized: "Deny")
        )
        cancel.keyEquivalent = "\u{1b}"

        Task { @MainActor in
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                request.approve()
            } else {
                request.deny()
            }
        }
    }

    /// Bounded, read-only preview of the text under decision, mirroring
    /// the preview area in Ghostty's own confirmation dialog.
    private static func clipboardPreview(_ contents: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        // A pathological clipboard can be arbitrarily large; the decision
        // only needs a glimpse.
        text.string = String(contents.prefix(4096))
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }
}
