# Releasing zshell

zshell auto-updates with [Sparkle](https://sparkle-project.org). Releases are
**GitHub Release assets** of this repository, so shipping needs no domain and no
object store: each version's **`.dmg`** hangs off its own `v<version>`
release, while the update archives and `appcast.xml` sit on one permanent
**`updates`** release. New users download the DMG; existing users get smaller
in-app delta updates via Sparkle, which reads the appcast at
`https://github.com/wzz6423/zshell/releases/download/updates/appcast.xml`,
verifies each build's EdDSA signature, and installs it. One release command
produces both.

That split is what keeps update URLs stable: Sparkle resolves every enclosure in
the feed — including the items describing older versions — against a single
prefix, so every archive has to stay under one tag that never moves.

Run release commands from `mac/`. Once set up, cutting a release is one command:

```sh
bun scripts/release.ts        # or: bun run release
```

- Updater code: [`zshell/Updater.swift`](zshell/Updater.swift) — **Check for Updates…**
  (app menu) and the **Updates** section in Settings.
- Feed URL + public key: [`zshell/Info.plist`](zshell/Info.plist)
  (`SUFeedURL`, `SUPublicEDKey`).
- Release automation (Bun + TypeScript): [`scripts/release.ts`](scripts/release.ts),
  [`scripts/generate-appcast.ts`](scripts/generate-appcast.ts),
  [`scripts/ExportOptions.plist`](scripts/ExportOptions.plist).

---

## One-time setup

The release script runs on [Bun](https://bun.sh) (`brew install bun`) and builds
the disk image with [`create-dmg`](https://github.com/create-dmg/create-dmg)
(`brew install create-dmg`). Optionally run `bun install` once for editor
type-checking of the scripts — it isn't needed to run them.

### 1. Sparkle signing keys

Every update is signed with an ed25519 key. The **private** key stays in your
login keychain under the `zshell-update-ed25519` account; the **public** key ships
in the app.

Download the Sparkle tools (`Sparkle-<version>.tar.xz` from the
[releases page](https://github.com/sparkle-project/Sparkle/releases)), unpack,
then:

```sh
./bin/generate_keys --account zshell-update-ed25519
```

Copy the printed public key into [`zshell/Info.plist`](zshell/Info.plist), replacing
the existing `SUPublicEDKey` value. Back the private key up somewhere safe:

```sh
./bin/generate_keys --account zshell-update-ed25519 -x sparkle_private_key.txt   # export → password manager
./bin/generate_keys --account zshell-update-ed25519 -f sparkle_private_key.txt   # import on another machine / CI
```

> ⚠️ Lose the private key and you can't ship updates to existing users. Keep it.

Put the Sparkle `bin/` on your `PATH`, or point the release at it with
`SPARKLE_BIN=/path/to/Sparkle/bin`.

### 2. Developer ID signing + notarization

For notarized distribution, sign the app with your **Developer ID**.
For Zisla-style ad-hoc distribution, skip this section and follow
[Free ad-hoc distribution](#free-ad-hoc-distribution) below.

- Install your **Developer ID Application** certificate in the login keychain.
  The script signs the `.dmg` with it too; if you have more than one such cert,
  set `SIGN_IDENTITY` to the exact name or SHA-1.
- Set `teamID` in [`scripts/ExportOptions.plist`](scripts/ExportOptions.plist)
  (find it with `xcrun security find-identity -v -p codesigning`).
- Store notarization credentials once as a keychain profile named `NOTARY`:
  ```sh
  xcrun notarytool store-credentials NOTARY \
    --apple-id you@example.com --team-id XXXXXXXXXX
  # (paste an app-specific password, or use --key for an App Store Connect API key)
  ```

### 3. GitHub CLI

Publishing goes through [`gh`](https://cli.github.com) (`brew install gh`), so
log in once as an account that can create releases in this repository:

```sh
gh auth status        # already logged in?
gh auth login         # if not
```

The release script verifies this before it starts building — a token that cannot
create releases must not surface only after a 20-minute notarized build.

Verify with `gh release list --repo wzz6423/zshell`.

---

## Cutting a release

1. **Bump the version** in the `zshell` target's build settings:
   - `MARKETING_VERSION` — user-visible, e.g. `1.1` (`CFBundleShortVersionString`).
   - `CURRENT_PROJECT_VERSION` — build number, e.g. `2` (`CFBundleVersion`).
     **Must increase every release** — Sparkle compares it to decide what's newer.
2. **Write the release notes** — add a `## [1.1]` section at the top of
   [`CHANGELOG.md`](../CHANGELOG.md) (the heading must match `MARKETING_VERSION`).
3. **Run it:**
   ```sh
   bun scripts/release.ts        # or: bun run release
   ```

That's it. The script archives → exports a Developer ID app → builds a
notarized, stapled **`.dmg`** → staples the app and zips it for Sparkle →
attaches the matching `CHANGELOG.md` section as release notes → pulls the 15
most recent archives from the `updates` release by default (so Sparkle can build
deltas) → regenerates `appcast.xml` → publishes the DMG on the `v<version>`
release and the archives on `updates`. When it finishes:

- **Download link** (for the website):
  `https://github.com/wzz6423/zshell/releases/download/v<version>/zshell-<version>.dmg`
- **In-app updates**: the appcast on the `updates` release.

### Free ad-hoc distribution

To use Zisla's free distribution path:

```sh
CODE_SIGN_IDENTITY=- \
SPARKLE_ED_KEY_FILE="/path/to/zshell-sparkle-ed25519-private-key.txt" \
NO_TAP=1 NO_SITE=1 bun scripts/release.ts
```

This signs the complete app and DMG ad-hoc, skips notarization and stapling, and may require **Open Anyway** on first launch. The Sparkle appcast is still signed with the EdDSA key file. Update the Homebrew cask and rebuild the website separately after the release is live.

In Developer ID mode, notarizing the DMG also notarizes the app's code, so the script staples both from
a single submission — the DMG for direct downloads, the app for the Sparkle zip.

Without `NO_TAP=1` and `NO_SITE=1`, it also bumps the **Homebrew cask** and
redeploys the **website** (both below). When those changes need review, keep
both flags set, submit the cask and website changes as pull requests, and let
the website deploy after merge.

A **Release Feeds** run starts the moment the release is published and polls until the
release and the feed agree: the DMG on `v<version>`, the appcast, archive and notes on
`updates`, every URL in the feed under the `updates` prefix, a signed enclosure, and the
newest item in the feed being *this* version — a `CURRENT_PROJECT_VERSION` that did not
move publishes a release nobody is ever offered and leaves the website on the old one.
It then downloads the DMG link anonymously, the way a visitor does. The same checks run
locally:

```sh
ruby ../.github/scripts/appcast-feeds.rb verify --tag v<version>
```

Test by running an **older** build and choosing **Check for Updates…**.

### Options

| Env | Default | Purpose |
| --- | --- | --- |
| `SPARKLE_KEY_ACCOUNT` | `zshell-update-ed25519` | keychain account holding the private EdDSA key |
| `SPARKLE_ED_KEY_FILE` | — | private EdDSA key file, used instead of the keychain account |
| `CODE_SIGN_IDENTITY=-` or `SIGNING_MODE=adhoc` | — | ad-hoc signing; skip Developer ID export, notarization and stapling |
| `RELEASE_REPO` | `wzz6423/zshell` | repository the releases are published to |
| `UPDATES_TAG` | `updates` | permanent release holding the appcast and archives |
| `NOTARY_PROFILE` | `NOTARY` | `notarytool` keychain profile |
| `SIGN_IDENTITY` | `Developer ID Application` | codesigning identity for the DMG |
| `EXPORT_OPTIONS` | `scripts/ExportOptions.plist` | export config |
| `DOWNLOAD_URL_PREFIX` | the `updates` release's download URL | base URL in the appcast |
| `HISTORY_COUNT` | `15` | number of recent archives to pull for delta generation |
| `BUILD_JOBS` | half of logical CPUs (min 1) | max concurrent `xcodebuild` tasks during archive (limits parallel `swift-frontend` work) |
| `BUILD_NICE=1` | — | archive under utility QoS (`taskpolicy`) so interactive work keeps priority |
| `TAP_REPO` | `wzz6423/homebrew-tap` | tap holding the Homebrew cask |
| `TAP_CASK` | `Casks/zshell.rb` | cask path within the tap |
| `TAP_DIR` | `build/homebrew-tap` | local checkout of the tap |
| `FORCE=1` | — | re-release a version that already exists |
| `NO_TAP=1` | — | skip bumping the Homebrew cask |
| `SITE_WORKFLOW` | `Web Pages` | workflow that rebuilds the website |
| `SITE_BRANCH` | `main` | branch that workflow deploys |
| `NO_SITE=1` | — | skip redeploying the website |
| `NO_HISTORY=1` | — | skip pulling old archives (full updates, no deltas) |

Release builds use whole-module Swift optimization, so a single `swift-frontend`
can still use multiple cores even with a low `BUILD_JOBS`. Use `BUILD_JOBS=2`
(and optionally `BUILD_NICE=1`) if the archive step makes the machine lag.

---

## The Homebrew cask

zshell is also installable with `brew install wzz6423/tap/zshell`, from the
cask at [`wzz6423/homebrew-tap`](https://github.com/wzz6423/homebrew-tap)
(`Casks/zshell.rb`). The tap is shared with other projects, so the release script
refreshes the repository's default branch and changes only this cask. If the file
does not exist yet, the first release creates it without touching the other
recipes. The cask downloads the same `.dmg` from that version's release, so it
needs the new version and its `sha256` after every release.

`scripts/release.ts` does that for you as its last step
([`scripts/bump-cask.ts`](scripts/bump-cask.ts)): it hashes the DMG it just
built, clones/refreshes the tap under `build/homebrew-tap`, rewrites the
`version` and `sha256` stanzas, and pushes a `zshell <version>` commit. It needs
**push access to the tap over SSH** — nothing else.

The bump runs *after* the upload, so the hash always covers a DMG that's already
fetchable, and a failure there is a warning rather than a failed release — the
release is live either way. Retry it on its own:

```sh
bun scripts/bump-cask.ts 1.1     # downloads the published DMG if it's not in build/
```

Re-running when the cask already names that version is a no-op. Set `NO_TAP=1`
to skip the bump entirely.

The cask marks `auto_updates true`; the app therefore invokes
`brew upgrade --cask --greedy-auto-updates zshell` for Homebrew installs. Its
`depends_on macos:` mirrors the app's `LSMinimumSystemVersion`, which
the bump doesn't touch — it only warns when the two drift apart. If you raise the
deployment target, edit that stanza in the tap by hand.

---

## The website

[The website](https://wzz6423.github.io/zshell/) is a static site on GitHub Pages, prerendered by
the `Web Pages` workflow. Its download buttons read the version, the minimum
system, and the DMG URL out of the appcast **while it is being prerendered** —
there is no server to ask at request time, so the site keeps advertising the
release it was last built against.

`scripts/release.ts` therefore dispatches that workflow as its final step, after
the appcast is up:

```sh
gh workflow run "Web Pages" --ref main
```

It needs the `gh` CLI, logged in with access to this repository. Like the cask
bump this runs after the release is live, so a failure is a warning with that
command to retry, and `NO_SITE=1` skips it. A push to `main` that touches `web/`
deploys the site too — the dispatch exists for releases, which change nothing in
the repository.

---

## Notes

- **Two artifacts per release:** a notarized `.dmg` (what people download) and a
  `.zip` (what Sparkle installs, with binary deltas). Only the `.zip` goes in the
  appcast; the website's download button points at
  `https://github.com/wzz6423/zshell/releases/download/v<version>/zshell-<version>.dmg`,
  which [`web/src/lib/release.ts`](../web/src/lib/release.ts) builds from the
  version it read out of the feed. Need a URL that never changes?
  `https://github.com/wzz6423/zshell/releases/latest` always resolves to the
  newest version's release page.
- **Automatic checks:** by default Sparkle asks the user once whether to allow
  automatic update checks. To opt in by default (no prompt), add to
  [`zshell/Info.plist`](zshell/Info.plist):
  ```xml
  <key>SUEnableAutomaticChecks</key>
  <true/>
  ```
  The **Updates** settings toggle lets users change it either way.
- **Release notes** live in [`CHANGELOG.md`](../CHANGELOG.md). The release script
  publishes the matching version section as `zshell-<version>.md` next to the
  archive, and `generate_appcast` links it as the update's release notes
  (Sparkle 2.9+ renders Markdown). No matching section → the release just ships
  without notes. Notes for older versions stay on the `updates` release, so they
  keep showing.
- `SUPublicEDKey` must match the private key used to sign the appcast. A mismatch
  lets the app check the feed but makes update installation fail signature verification.
- zshell isn't sandboxed, so no Sparkle XPC services need bundling.
- Old archives stay on the `updates` release so users far behind can still
  download them. Only the recent archives needed for new deltas are staged under
  `build/`, which is git-ignored.
