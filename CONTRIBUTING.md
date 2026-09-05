# Contributing to Zshell

For anything larger than a fix, open an issue first —
Zshell says no to features that fit some other tool better, and it's kinder to find
that out before the work.

## Issue

Thank you for opening an issue. Search existing Issues and Discussions first so that reports are not duplicated.

- Use `[Bug] Short problem description` for bug reports, for example `[Bug] Closing the git panel loses focus in the active pane`. Include the zshell version, macOS version and device, installation method, reproduction steps, expected behavior, and actual behavior.
- Use `[Feature] Short request description` for feature requests, for example `[Feature] Remember the file tree scroll position per project`. Describe the problem, the proposed solution, and alternatives you considered.
- Pick one **Area** in the form. It is required and decides the `area:*` label: `Feature Development`, `Bug Fix`, `CI & Build`, `Documentation`, or `Community & Discussion`. The Simplified Chinese forms offer the same options and map to the same labels.
- Say which terminal backend the problem needs, Ghostty or Alacritty, when the report touches the terminal itself. They are separate implementations and a bug rarely reaches both.
- Remove tokens, account details, local paths, and other sensitive information from logs, screenshots, and recordings.
- Report security vulnerabilities privately through [Security Advisories](https://github.com/wzz6423/zshell/security/advisories/new) instead of opening a public issue.
- Automation applies `bug` or `enhancement` together with the matching `area:*` label, and leaves every other label untouched. When the title prefix or a required field does not follow the form, it also applies `needs-more-info` and keeps a single comment listing what is missing; edit the issue and that comment updates itself.

## Development setup

```bash
git clone --recurse-submodules https://github.com/wzz6423/zshell.git
```

Already cloned? `git submodule update --init --recursive`. A full Xcode
installation is required to build the app. Bun is also needed for `web/` and
`mac/scripts/`.

A Rust toolchain ([rustup](https://rustup.rs)) is required: the Alacritty
backend's bridge in `mac/Vendor/alacritty-bridge` is a Rust static library, built
from an Xcode build phase. Building for a second architecture needs its target
installed too — `rustup target add x86_64-apple-darwin`.

`mac/Vendor/STTextView` is a fork of STTextView with five `// zshell patch` sites
across three files, and `mac/zshell.xcodeproj` references it as a *root package* — a
folder in the project's top-level group — rather than through Xcode's **Add
Package Dependency… > Add Local…**. That distinction is load-bearing:
`STTextView-Plugin-Neon` depends on `krzyzanowskim/STTextView`, SwiftPM derives
package identity from the last path component, so the fork and the remote both
claim `sttextview`. Only a root package may override a same-identity dependency.
Registered as a local package reference the fork instead resolves alongside a
`Conflicting identity for sttextview` warning that Apple has said will become an
error. Re-add the fork by dragging the folder into the project; never through
**Add Local…**.

### Local development signing

Debug builds use an Apple Development certificate from your own login keychain.
Create the ignored local configuration from the tracked template, then replace
only its placeholder Team ID:

```bash
cp mac/Config/Local.example.xcconfig mac/Config/Local.xcconfig
```

`mac/Config/Local.xcconfig` is ignored and must never be committed. Keep
`CODE_SIGN_IDENTITY = Apple Development`. Confirm that an Apple Development
identity is available, then set `DEVELOPMENT_TEAM` to the `OU` value in that
certificate's subject:

```bash
security find-identity -v -p codesigning
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

Developer ID certificates, notarization credentials, and Sparkle private keys
are release-only materials. Configure them only as described in
[RELEASING.md](mac/RELEASING.md); do not put them in `Local.xcconfig` or the
repository.

### Build and verify

Open `mac/zshell.xcodeproj` and run the `zshell` scheme, or:

```bash
xcodebuild -project mac/zshell.xcodeproj -scheme zshell -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

Add `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` if you only have Xcode beta.

`make run` builds and launches the Debug app in one step, and `make update`
restarts a running one. Verify the resulting bundle with:

```bash
make run
codesign --verify --deep --strict --verbose=2 'mac/build/debug/Build/Products/Debug/zshell Debug.app'
```

`make build-package` produces a local Developer ID-signed Release app and DMG
without notarizing or publishing it. `make clean` stops the Debug app and
removes build and website artifacts. All of these write to `mac/build/` or other
ignored output directories; remove them before committing.

A Debug build is `sh.zshell.dev` and keeps its own state, so it can run beside an
installed Zshell without clobbering it: settings go to
`~/.config/zshell-dev/config.toml`, and the session snapshot, sidebar widths, and
Sparkle preferences live under the separate bundle id.

Repository skills live in [`skills/`](skills/). Use
[app development](skills/zshell-app-development/SKILL.md) for implementation and validation,
and [release](skills/zshell-release/SKILL.md) for release preparation or publishing.
The app-bundled `zshell-automation` skill remains in `mac/zshell/Skills/`.

## Website and docs

The site is in [`web/`](web/README.md); user documentation is MDX under
`web/content/docs`. It is written for people using the app — anything that only
matters when you are building it belongs here instead. See the
[website guide](web/README.md) for local commands, prerendering, deployment,
and documentation URLs.

## Localization

Zshell’s development language is English, with Simplified Chinese and Japanese
translations maintained in Xcode String Catalogs. See
[LOCALIZATION.md](mac/LOCALIZATION.md) for translating existing text, adding a
language, testing a localization, and writing localizable Swift.

Translation-only pull requests are welcome. Xcode’s catalog editor and XLIFF
export/import workflow both work; contributors do not need to edit Swift.

## Branches and commits

- Create branches from the latest `main` and prefix them with the type the pull request will declare — `feat/` (or `feature/`), `fix/`, `docs/`, `style/`, `refactor/`, `perf/`, `test/`, `chore/`, `build/`, `ci/`, or `revert/` — such as `fix/pane-focus-loss` or `ci/skip-directive-timing`.
- Use the English [Conventional Commits](https://www.conventionalcommits.org/) format, such as `type(scope): description` or `fix(terminal): restore focus after closing the git panel`.
- Keep one branch and one pull request focused on one clear goal; avoid formatting-only changes and unrelated refactors.
- `publish-v*` branches are reserved for release maintenance. Submit all other contributions to `main`.

## Pull Request

Thank you for opening a pull request. Check these requirements while it is awaiting review.

- The **PR title** must use an English Conventional Commit subject, for example:
  - `feat(terminal): add per-pane scrollback search`
  - `fix(git): resolve stale diff after a branch switch`
  - `docs: update contributing guidelines`
  Allowed types are `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `build`, `ci`, and `revert`.

- The **PR body** must be in English and contain the `Summary`, `GitHub Project`, `PR Type`, `Validation`, `Risk and Rollback`, `Related Issue`, and `AI Attribution` sections that `.github/PULL_REQUEST_TEMPLATE.md` provides.
  - `GitHub Project` keeps the template value `- Project: zshell Development`. `Project Automation` reads it to place the pull request on the shared board.
  - `PR Type` declares exactly one `- Type:` value, and it must match the type in the title. `PR Automation` turns it into a label, for example `fix` into `bug`.
  - Every `Validation` block must declare `passed`, `failed`, or `not run`. `passed` and `failed` need `Command` and `Result`; `not run` needs `Reason`.
  - `Related Issue` must either close an issue with a keyword such as `Closes #123`, which also applies the `development` label, or be exactly `None`.
  - `AI Attribution` must declare `- Agent:`. Any agent other than `None` requires a matching `- Co-authored-by: Name <email>` line, which must also appear as a trailer on at least one commit, and applies the `ai-assisted` label.

  Example:

  ```markdown
  ## Summary
  - Add a repository hygiene check.

  ## GitHub Project
  - Project: zshell Development

  ## PR Type
  - Type: ci

  ## Validation
  - Status: passed
  - Command: bash .github/scripts/check-repository-hygiene.sh
  - Result: Repository hygiene check passed.

  ## Risk and Rollback
  - Risk: Only repository automation is affected.
  - Rollback: Revert this pull request.

  ## Related Issue
  Closes #123

  ## AI Attribution
  - Agent: Claude Code
  - Co-authored-by: Claude <noreply@anthropic.com>
  ```

- The `PR Quality` check validates this format; a pull request cannot be merged while the check is failing. `PR Automation` then applies the labels and assigns the pull request.
- There is no unit test target: app changes are proven by building and running Zshell and exercising the change, so say in `Validation` what you did and attach screenshots or a recording for UI work. Run `cargo test --locked` in `mac/Vendor/alacritty-bridge` for bridge changes, `bun run typecheck && bun run build` in `web/` for site changes, and `bunx tsc --noEmit` in `mac/` for anything under `mac/scripts/`. Install dependencies with `bun install --frozen-lockfile` in each package before running Bun checks.
- Build all new UI in AppKit. SwiftUI is legacy and must not be introduced or expanded; materially changing an existing SwiftUI view means migrating the affected UI to AppKit.
- Update the relevant documentation when changing user-visible behavior, build instructions, or the release process. [CHANGELOG.md](CHANGELOG.md) is written for end users, so it records the shipped outcome rather than the fixes and refactors on the way there, and the version is bumped only by a release, never by a pull request.
- Do not commit `mac/build/`, `mac/Vendor/alacritty-bridge/target`, `node_modules`, `dist`, downloaded files, logs, tokens, signing materials, or personal data. `Repository Hygiene` fails on them.
- `main` and `publish-v*` are protected and can only be updated through a reviewed pull request that passes its checks.

## Skipping CI

Maintainers and requested reviewers can skip checks that a change cannot affect, for example a documentation-only fix. Write the directive on its own line in a pull request comment:

| Directive | Effect |
| --- | --- |
| `skip-all` | Skips every workflow listed in `.github/ci-skip.json`. |
| `skip-<workflow>` | Skips one workflow by name, file name or alias, such as `skip-mac`, `skip-web-ci` or `skip-Web CI`. |
| `unskip-all` | Clears every skip directive. |
| `unskip-<workflow>` | Restores one workflow. |

- Free text may follow the directive, for example `skip-all: documentation only change`.
- A workflow may be named the way GitHub displays it, spaces included, so `skip-Repository Hygiene` and `skip-hygiene` are the same directive. The longest name that matches wins and the words left over become the note.
- Directives are honored only from the repository owner, an organization member, a collaborator, or a requested reviewer. Bot comments are ignored.
- `CI Skip` cancels the runs in flight, reports the skipped checks as successful so the required checks stay satisfied, applies the `skip-ci` label, and edits one summary comment with the current decision.
- The whole comment thread is replayed on every comment, so the newest directive always wins.
- A directive expires as soon as a newer commit is pushed: it can only speak about the code its author had seen, and a check reported as successful would otherwise let the new commit merge unbuilt. `CI Skip` re-runs on every push to drop the `skip-ci` label and restore the checks, and the summary comment lists the directives that expired. Comment the directive again to skip the new commit as well.
- A maintainer can re-apply the current decision without a new comment from **Actions -> CI Skip -> Run workflow**, passing the pull request number.
- `.github/ci-skip.json` maps each workflow to the check names it publishes. `Test CI Scripts` fails when the manifest drifts from the workflow files.

## Path-scoped checks

A platform workflow only runs when the pull request touches the files it builds, so a documentation change never boots a macOS runner:

| Workflow | Runs when the pull request touches |
| --- | --- |
| `macOS App` | `mac/zshell/**`, `mac/zshell.xcodeproj/**`, `mac/Vendor/**`, `mac/Config/**`, `mac/Makefile`, `Makefile`, `mac/scripts/build-alacritty-bridge.sh`, `.github/**` |
| `Release Scripts` | `mac/scripts/**`, `mac/package.json`, `mac/bun.lock`, `mac/tsconfig.json`, `.github/**` |
| `Web CI` | `web/**`, `.github/**` |

- The `paths` field of `.github/ci-skip.json` owns the scopes, and a workflow that declares none always runs. `CI Lint`, `Repository Hygiene`, `PR Quality Gates`, `CodeQL` and `Dependency Review` therefore run on every pull request.
- `mac/scripts/build-alacritty-bridge.sh` is deliberately owned by two workflows: it lives under `mac/scripts/`, but it is also the Xcode build phase that produces the Alacritty backend's static library.
- Any change under `.github/` runs everything, because a change to CI must be proven against every platform.
- The jobs are skipped by a job condition instead of a workflow `paths:` filter, so a required check reports success rather than staying pending forever.
- A renamed file is matched under both its old and its new path, and the comparison ignores case.
