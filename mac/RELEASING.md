# Releasing zshell

The stable macOS release is published to **GitHub and Gitee**. Each host receives
Apple Silicon (`arm64`), Intel (`x86_64`), and Universal packages built from the
same Release archive. This workflow supports stable releases; it does not publish
Preview, Windows, or Linux builds.

Run commands from `mac/`. Publishing requires the maintainer's authorization.
Once that authorization is given, complete this release without asking again.
Homebrew and website changes are submitted as pull requests for the maintainer to
merge; the release command does not push the tap or deploy the website.

## Signing and credentials

Two independent signing identities protect the release:

- The fixed **`zshell Release Signing`** self-signed certificate signs the app,
  nested code, and DMG. Preserve the identity across releases so the app has a
  stable designated requirement. This is not ad-hoc signing or Apple
  notarization. First launch may require **System Settings → Privacy & Security
  → Open Anyway**.
- The existing Zshell **Sparkle Ed25519 key** signs both ZIP enclosures and the
  complete appcasts. Its public key ships as `SUPublicEDKey`; signed feeds are
  required by `SURequireSignedFeed`. Never replace this key to repair a failed
  signing check, and never reuse another application's private key.

Create the code-signing identity only once, using an existing private backup
directory approved by the maintainer:

```sh
python3 scripts/setup-release-signing.py --backup-directory /path/to/private-backups
```

This creates `~/Library/Keychains/zshell-release-signing.keychain-db`. Its
password is stored in the login Keychain as the generic password service
`sh.zshell.release-signing-keychain`. The script backs up the encrypted private
key (PEM), certificate (PEM), and identity (P12), with mode `600`, and refuses to
overwrite an existing identity or backup. Preserve both the backups and their
password in private storage. Never print credentials or include private keys,
passwords, personal paths, or certificate serial numbers in logs, PRs, or releases.

Set `SPARKLE_ED_KEY_FILE` to the existing Zshell update key file (mode `600`).
The release script checks that it matches the app's public key before building.
Set `SPARKLE_BIN` if Sparkle's `generate_appcast` and `sign_update` tools cannot be
found in the existing Xcode artifacts.

GitHub uses `gh auth login`, `GH_TOKEN`, or `GITHUB_TOKEN`. Gitee uses
`GITEE_RELEASE_TOKEN` or an existing private Keychain credential. Both credentials
must have release write access to the public `wzz6423/zshell` repository. Tokens
are consumed privately; do not echo them to test authentication.

## Prepare and build

The 0.1.1 release is the first release built from this aligned workflow after the
0.1.0 bug-fix merge. Prepare and review the release source before publishing.

1. Read [the release preflight](../skills/zshell-release/references/preflight.md).
2. Set the maintainer's intended `MARKETING_VERSION` and increment
   `CURRENT_PROJECT_VERSION` in `zshell.xcodeproj/project.pbxproj`. Sparkle uses
   the build number to decide which version is newer. Ordinary feature PRs must
   not change release versions.
3. Ensure the matching version section in the root `CHANGELOG.md` describes the
   final user-visible release. Commit the release source and make the same commit
   available to both hosts before publishing.
4. Build and validate locally:

```sh
SPARKLE_ED_KEY_FILE=/path/to/zshell-update-key \
BUILD_JOBS=2 bun scripts/release.ts --local
```

`--local` performs the complete archive, three-architecture packaging, app and
DMG signing, SHA-256 generation, ZIP signing, and six signed appcast generation.
It does not contact the release APIs or publish anything. The output is
`build/release-v<version>/`; `RELEASE_OUTPUT_DIRECTORY` can select another location.
The architecture check covers every nested Mach-O binary, not only the launcher.

To resume packaging from an archive recorded against the same source commit:

```sh
SPARKLE_ED_KEY_FILE=/path/to/zshell-update-key \
bun scripts/release.ts --local --package-only
```

Use a fresh output directory after a source change. Never silently reuse an
archive from another commit or replace published binaries with a different
build under the same asset names.

## Publish and verify

Omitting `--local` builds and then publishes to both hosts. To publish already
validated local output without rebuilding:

```sh
bun scripts/publish-release.ts --publish build/release-v<version> <version> <source-commit>
bun scripts/publish-release.ts --verify build/release-v<version> <version> <source-commit>
```

Each `v<version>` release must contain **15 required assets**:

| Architecture | Packages and checksum files | Signed feed |
| --- | --- | --- |
| `arm64` | `zshell-v<version>-macOS-arm64.{dmg,zip}` and each `.sha256` | `appcast-arm64.xml` |
| `x86_64` | `zshell-v<version>-macOS-x86_64.{dmg,zip}` and each `.sha256` | `appcast-x86_64.xml` |
| `universal` | `zshell-v<version>-macOS-universal.{dmg,zip}` and each `.sha256` | `appcast.xml` |

Checksums use the bare package filename. Every appcast has exactly one item,
references the matching architecture's ZIP under that host's version tag, and
carries both an enclosure signature and a whole-feed signature. GitHub feeds
reference GitHub ZIPs; Gitee feeds reference Gitee ZIPs.

The app checks these permanent URLs, with the architecture suffix above:

- Primary: `https://gitee.com/wzz6423/zshell/releases/download/update-release/appcast.xml`
- Fallback: `https://github.com/wzz6423/zshell/releases/latest/download/appcast.xml`

Gitee's `update-release` contains only the three signed feeds and must be created
before the version release: Gitee assigns its latest badge by release creation
order. The publisher uploads and verifies packages on both hosts before changing
current feeds. GitHub's new release remains a draft until its asset set is ready.
An existing release is updated without creating a duplicate tag.

The publisher verifies local checksums and Ed25519 signatures, remote asset
hashes, and all six public feed responses against the local signed files. Also
verify anonymous package downloads and mount each DMG to check `zshell.app` and
the Applications symlink. Do not treat a signature field's presence as a
successful installation test.

Test an older Release installation through **Check for Updates…** to verify
feed signature, archive signature, replacement, and restart. Verify Gitee first,
then one GitHub retry when the primary feed or package download fails. Thin
installs retain their architecture, Universal retains both slices, and an Intel
app running under Rosetta migrates to Apple Silicon. Debug does not initialize
Sparkle and cannot substitute for this test. Record any unavailable test machine
or incomplete installation test explicitly.

## Homebrew and website PRs

After both releases verify, update `Casks/zshell.rb` in `wzz6423/homebrew-tap`
through a PR. The cask selects the native architecture's **ZIP**, uses its exact
SHA-256, and preserves `#{version}` and `#{arch}` URL interpolation. Keep
`auto_updates true` and the app's minimum macOS requirement. Run cask syntax and
Homebrew validation before submitting; do not push the tap's default branch.

Direct and Homebrew installations both use Sparkle. A manual
`brew upgrade --cask --greedy-auto-updates zshell` remains available for an
explicit Homebrew upgrade or a lagging installation.

The website reads the Gitee feed with GitHub fallback during prerendering.
It advertises three DMGs plus Gitee mirror links only after the current feed
references a canonical architecture package. Until then, the existing Universal
download remains the fallback. The canonical package URL is:

```text
https://<github|gitee>.com/wzz6423/zshell/releases/download/v<version>/zshell-v<version>-macOS-<architecture>.dmg
```

Update the fallback version and installation documentation in the website PR.
Run `bun run build` and `bun run typecheck` from `web/`. The website deploys after
the maintainer merges the PR; do not deploy unmerged website changes.

## Release notes, compatibility, and cleanup

State that this is a stable macOS release, its signing and notarization status,
first-launch steps, supported architectures, and actually tested macOS versions.
Link issues and PRs to GitHub; Gitee is the release mirror. If including product
screenshots, upload them as versioned release assets and verify that the URLs in
each host's release body return the expected PNG bytes.

The original 0.1.0 ad-hoc build 2 retains its legacy download names. Release 0.1.1
uses the canonical architecture names and a higher Sparkle build number; preserve
the existing Ed25519 trust key and legacy downloads during this migration. The old
`updates` feed belongs to those existing installations and must remain usable until
their migration has been verified.

Only after verification and recovery are complete, remove this run's archive,
derived data, staging directories, test installations, downloads, and temporary
files. Retain requested deliverables and private signing backups. Do not run a
broad `make clean` that stops or deletes another task's Debug build. Recovery
procedures are in [troubleshooting](../skills/zshell-release/references/troubleshooting.md).
