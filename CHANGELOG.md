# Changelog

All notable changes to zshell. This file is the **source of truth for the release
notes shown in the in-app updater**: [`mac/scripts/release.ts`](mac/scripts/release.ts)
extracts the section whose heading matches the version being released
(`MARKETING_VERSION`) and publishes it next to the update, so Sparkle shows it in
the update prompt.

Format follows [Keep a Changelog](https://keepachangelog.com). Add a new
`## [<version>]` section at the top for each release, matching the version you
set in the Xcode project.

Write release notes for the final product users receive, not the development
history. When a feature is still unreleased, fold its fixes and refinements into
the original feature bullet instead of adding separate entries for them.

## [Unreleased]

### Added

- Show the processes running in a shared remote session in the Info panel.

### Fixed

- Use a consistent compact switch size throughout Settings.
- Return keyboard focus to the previous pane when the command palette opened
  over the agent palette is closed.
- Stop the menu bar from flickering while zshell is in front, and keep the Terminal menu before Window and Help.
- Keep the configured cursor shape in Alacritty terminals restored from
  background sessions instead of always showing a block.

## [0.1.11]

### Added

- Optionally keep local shells, agents, and development servers running after
  quitting Zshell, then reconnect to their original terminal state on reopening.
  Use Quit and End All Sessions to stop all background work.
- Share host-owned terminal sessions over SSH or Tailscale and reconnect after
  the client quits or loses its connection. Manage connections, server installation,
  Mac sharing, and input control in the app, with remote hosts on macOS or Linux.
- Keep Quick Terminal workspaces with split panes and running jobs between
  openings, or choose a fresh workspace each time.
- Choose Dock only, Dock and menu bar, or menu bar only. In menu bar modes,
  closing the last workspace window keeps its terminals available when reopened.
- Manage branches and Git worktrees from the Git panel, create terminal sessions
  in isolated worktrees, and choose whether to keep or safely remove the checkout
  when closing. Manage sessions from an external terminal with `zshell +session`.
- Search, archive, and resume saved Claude Code, Codex, Pi, and OpenCode
  conversations after closing their panes or restarting Zshell. Follow remote
  Agent activity and resume saved conversations on their original host.
- Track each Codex conversation in its own pane when multiple terminals share
  an app-server daemon, and resume the verified conversation in the correct pane.
- See Agent progress, waiting reasons, and subtasks from supported integrations
  or explicit program reports.
- Review changes from an Agent's latest turn, all uncommitted changes, or a
  branch. Keep or revert individual text hunks from the latest turn without
  changing the staging area.
- Inspect and operate project browser panes through the CLI, capture background
  pages, evaluate page scripts, and save or restore site cookies and local storage.
- Block browser ads and trackers with EasyList and EasyPrivacy, and manage
  filter lists and custom ABP subscriptions in Browser settings.
- Run commands in background panes and wait for each task's exit status,
  duration, and saved recent output, including waiting again after a timeout.
- Follow live project, pane, Agent, and command events through `zshell +events`.
- Paste clipboard screenshots as private PNG paths in local terminals, and
  upload local files or screenshots when pasting into remote terminals on either
  backend.
- Optionally focus terminal panes by moving the mouse into them, including
  Quick Terminal.
- Apply external configuration edits while Zshell is running, preserve linked
  dotfiles and their permissions when saving, and use the login shell's SSH
  agent when launching from the Dock or Finder.
- Let terminal programs request camera access and permission to control other
  apps, with localized macOS permission prompts.

### Changed

- Find settings through a searchable sidebar, grouped cards, navigation history,
  and appearance previews.
- Enable Vim command hints, terminal history restoration, failed-command
  notifications, and automatic update downloads by default for new
  configurations, while preserving existing choices.
- Refresh the website, documentation, and changelog with a shared appearance,
  persistent theme controls, and a particle background that respects reduced
  motion.

## [0.1.10]

### Fixed

- Harden document loading in the built-in diff viewer.

## [0.1.9]

### Added

- Show the current app version in the bottom-left corner of the Settings sidebar.

### Changed

- Use a bar cursor by default when no cursor shape is configured, while keeping
  existing cursor preferences.

### Fixed

- Restore input selection editing in zsh and Claude Code on both terminal
  backends, including typing before releasing the mouse and clearing stale
  selection highlights.

## [0.1.8]

### Added

- Offer 17 languages in the macOS app and website, with in-app language changes
  keeping active terminal sessions running.
- Choose automatic installation separately from automatic downloads, with an
  opt-in to install prepared updates and restart Zshell automatically.
- Open available updates from an indicator in the project sidebar.

## [0.1.7]

### Added

- Enable searchable, mode-aware Vim command hints in the session info panel,
  with English, Simplified Chinese, and Japanese descriptions for local and SSH
  sessions on both terminal backends.
- Block Zshell shortcuts for an individual pane so foreground terminal
  applications can handle those commands.

### Changed

- Apply language changes immediately across the app without restarting active
  terminal sessions.

### Fixed

- Edit Claude Code input reliably on both terminal backends: click to position
  the caret, replace selected text by typing or pasting, and preserve edits
  through terminal redraws.
- Prevent duplicate voice insertion into terminal input.
- Keep remote project details and Vim command hints usable in narrow sidebars.

## [0.1.6]

### Fixed

- Show complete session names in the scrollable tab strip, and place the
  ellipsis at the end of project names that do not fit in the sidebar.

## [0.1.5]

### Added

- Choose whether Zshell downloads and installs updates automatically in Settings.

### Changed

- Prefer Gitee for updates in mainland China and GitHub elsewhere, with the other
  source available as a fallback.
- Recommend Zisla in the desktop application list instead of Zshell itself.

## [0.1.4]

### Added

- Browse recommended development tools in Settings, install or update them
  individually or in batches, and automatically check for available updates.
- Search file contents within a project or across open projects, and preview
  Markdown files directly in the editor.
- Use Quick Launch to save, group, and run frequent commands or SSH connections
  in fresh projects, including from the `zshell` command line.
- Open remote SSH projects with saved connection authentication, and organize
  local or remote projects with reorderable sidebar groups and Finder folder
  drops.
- Review repository changes from the Git panel, and use a built-in terminal
  multiplexer, prompt queue, and long-command notifications to manage active
  terminal work.
- Manage sessions more directly with tab renaming, color markers, pinning,
  reopening, grouping, and moves between compatible projects or windows while
  preserving their running terminals and split layouts.
- Customize the interface and terminal with appearance scaling, alternate app
  icons, settings import and export, remapped shortcuts, startup programs,
  environment setup, quick commands, terminal themes, opacity, and blur.
- Monitor agent usage and limits from the workspace while keeping agent work
  visible alongside files, diffs, and terminals.
- Make copying terminal selections configurable from Terminal settings.

### Fixed

- Terminal links now recognize web addresses without a scheme, including
  `www.baidu.com`, `baidu.com/docs`, and `localhost:3000`, so Command-click
  and the context menu open them like `https://` links. Ordinary dotted words such as
  file names still stay plain text.
- Improve terminal interaction across both backends, including mouse-aware
  applications, selection autoscrolling, IME composition, text metrics, and
  first-pane mounting.
- Restore reliable sidebar grouping, tab scrolling and pane transfers, row
  button actions, workspace sizing, and appearance behavior.
- Reduce unnecessary large-file highlighting and file reload work while keeping
  project views accurate after terminal directory changes.

## [0.1.3]

### Added

- Browse every Git worktree with its branch and checkout path in the Git panel,
  then open a selected checkout in a new terminal tab.

## [0.1.2]

### Fixed

- Git status refreshes reliably when the same path appears more than once in a
  repository status result.
- The session strip keeps clear space for the trailing controls without losing
  the header's window-drag area.

## [0.1.0]

### Changed

- Settings is now a sidebar of categories — General, Appearance, Terminal,
  Editor, Automation, and Updates — in a taller, resizable window that
  remembers its size and position.
- Editor line wrapping, AI agent coordination, and automatic update checks
  start out enabled.
