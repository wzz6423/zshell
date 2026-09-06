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

## [0.1.1]

### Fixed

- Clicking the terminal no longer inserts selection control sequences into the
  command line, including after keymap changes and in nested or replacement
  shells.

## [0.1.0]

### Changed

- Settings is now a sidebar of categories — General, Appearance, Terminal,
  Editor, Automation, and Updates — in a taller, resizable window that
  remembers its size and position.
- Editor line wrapping, AI agent coordination, and automatic update checks
  start out enabled.

## [unreleased]
