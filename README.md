# Zshell

**English** | [简体中文](README.zh-CN.md)

Zshell is a native macOS terminal workspace for developers who keep shells,
projects, source code, and AI coding agents moving at the same time. It keeps
the terminal primary while making files, diffs, repository state, and project
controls quick to inspect.

Zshell requires macOS 15.6 or later.

## Highlights

- Native AppKit interface for projects, tabs, and split panes
- libghostty by default, with an optional Alacritty backend
- Integrated browser tabs and panes
- File tree, Git status, and editable diffs
- Command palette, project-wide file search, and local path links
- AI agents can delegate background work and coordinate across Zshell panes, with provider-reported status and human-controlled approvals

## Get started

Download the latest release from [the Zshell website](https://wzz6423.github.io/zshell/), or install it
with Homebrew:

```sh
brew install wzz6423/tap/zshell
```

### Run from source

A full Xcode installation and the development dependencies described in
[CONTRIBUTING.md](CONTRIBUTING.md) are required.

```sh
git clone --recurse-submodules https://github.com/wzz6423/zshell.git
cd zshell
cp mac/Config/Local.example.xcconfig mac/Config/Local.xcconfig
# Set DEVELOPMENT_TEAM in mac/Config/Local.xcconfig for your Apple Development certificate.
make run
```

`make run` builds and launches the separately identified Debug app. See the
[local signing instructions](CONTRIBUTING.md#local-development-signing) before
sharing a build or diagnosing a signing failure.

## Repository layout

- [`mac/`](mac/) — macOS app, Xcode project, dependencies, and build/release scripts.
- [`web/`](web/README.md) — website and user documentation.
- [`skills/`](skills/) — [app development](skills/zshell-app-development/SKILL.md) and [release](skills/zshell-release/SKILL.md) workflows for coding agents.

The root `Makefile` provides `run`, `update`, `stop`, `build-package`, and `clean`.
Install Bun dependencies separately in `mac/` and `web/`; each has its own lockfile.

## Documentation

| Document | Purpose |
| --- | --- |
| [User documentation](https://wzz6423.github.io/zshell/docs) | Learn the app's workflows and settings. |
| [Contributing guide](CONTRIBUTING.md) | Set up the app, configure local signing, build, verify, and open a pull request. |
| [Release guide](mac/RELEASING.md) | Maintainer-only Developer ID, notarization, Sparkle, and GitHub Releases process. |
| [Security policy](SECURITY.md) | Supported versions and private vulnerability reporting. |
| [Localization guide](mac/LOCALIZATION.md) | Translate and test app text. |
| [Website guide](web/README.md) | Build and maintain the static site and its user documentation. |

## Contributing

Issues and pull requests are welcome. Read the
[contributing guide](CONTRIBUTING.md) first. Report security vulnerabilities
privately through [GitHub Security Advisories](https://github.com/wzz6423/zshell/security/advisories/new),
not a public issue.

Participation in this project is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[PolyForm Noncommercial License 1.0.0](LICENSE.md) — free for personal,
educational, research, and other noncommercial use.
