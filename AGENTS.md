# AGENTS.md

Zshell is a native macOS terminal workspace with projects, panes, a file tree, a git panel,
an editor, and a diff viewer. Existing SwiftUI code is legacy; AppKit is the UI foundation.

- [PRODUCT.md](PRODUCT.md) — who Zshell is for; product and design calls follow from it.
- [CONTRIBUTING.md](CONTRIBUTING.md) — build, verify, and what a PR must say. Read before opening one.
- [mac/RELEASING.md](mac/RELEASING.md) — maintainer-only. Never bump the version in a PR.

## Repository layout and skills

- `mac/` — the macOS app, Xcode project, vendored packages, build scripts, and release tooling.
- `web/` — the website and user documentation, with its own Bun package and lockfile.
- `skills/` — repository development and release workflows; app-bundled automation stays in `mac/zshell/Skills/`.
- For development, read [skills/zshell-app-development/SKILL.md](skills/zshell-app-development/SKILL.md).
- For release preparation or publishing, read [skills/zshell-release/SKILL.md](skills/zshell-release/SKILL.md).

## Verify

Build, run the app, exercise the change;

## Conventions

- Match the file you're in. Comments explain *why* — keep them, add them.
- SwiftUI is legacy and must not be introduced or expanded. Build all new UI in AppKit;
  when materially changing an existing SwiftUI view, migrate the affected UI to AppKit.
  UI architecture must prioritize maximum runtime performance over implementation convenience.
- [CHANGELOG.md](CHANGELOG.md) is the product changelog for end users, not a
  development log. Describe only the final user-visible outcome intended to
  ship. Never add or revise release notes for incremental fixes, refactors,
  implementation details, or regressions introduced and resolved while a
  feature is still in progress on an unreleased branch.
