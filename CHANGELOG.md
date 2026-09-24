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
