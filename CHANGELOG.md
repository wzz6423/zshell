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

- Move a tab to another project — including a project in another Zshell window —
  from the tab's context menu. The tab keeps its running shells, split layout,
  and focus while it moves.

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

## [unreleased]

### Added

- Scale tabs, icons, controls, and sidebars from Appearance settings while keeping terminal content at its configured font size.
- Quick Launch (⌘O): save the commands and SSH connections you start over and
  over, then fuzzy-search and launch any of them into a fresh terminal session.
  Entries are managed right in the launcher and stored per user, and a finished
  command or closed connection leaves a normal shell prompt in the pane.
