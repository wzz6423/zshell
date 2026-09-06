#!/usr/bin/env bun
//
// Automated zshell release:
//   archive → Developer ID export → notarize → staple → package →
//   sign & (re)generate the Sparkle appcast → publish to GitHub Releases.
//
// Download origin: this repository's own releases — the DMG on `v<version>`, the
// update archives and appcast.xml on the permanent `updates` release (see lib.ts).
//
// One-time setup (see RELEASING.md):
//   • Sparkle EdDSA keys in your keychain   — `generate_keys`
//   • Developer ID cert + notary profile    — `xcrun notarytool store-credentials`
//   • gh authenticated with repo scope      — `gh auth login`
//   • Fill in scripts/ExportOptions.plist (teamID)
//   • Push access to the Homebrew tap over SSH (for the cask bump)
//
// Usage:
//   bun scripts/release.ts            # release the version currently in the project
//   bun scripts/release.ts --local     # build signed artifacts without publishing
//   FORCE=1 bun scripts/release.ts    # re-release even if that version exists
//   NO_TAP=1 bun scripts/release.ts   # skip bumping the Homebrew cask
//   NO_SITE=1 bun scripts/release.ts  # skip redeploying the website
//   NO_HISTORY=1 bun scripts/release.ts   # skip pulling old archives (no deltas)
//   HISTORY_COUNT=3 bun scripts/release.ts   # use fewer prior archives for deltas
//   BUILD_JOBS=2 bun scripts/release.ts   # limit concurrent xcodebuild tasks
//   BUILD_NICE=1 bun scripts/release.ts   # archive under utility scheduling
//
// Bump MARKETING_VERSION (CFBundleShortVersionString) and CURRENT_PROJECT_VERSION
// (CFBundleVersion) in the project before running — Sparkle compares the build
// number to decide what's newer.
import { $ } from "bun";
import { existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { cpus } from "node:os";
import { join } from "node:path";
import {
  APPCAST_URL,
  RELEASE_REPO,
  UPDATES_TAG,
  UPDATE_URL_PREFIX,
  die,
  dmgUrl,
  need,
  say,
} from "./lib";
import { generateAppcast } from "./generate-appcast";
import { extractReleaseNotes } from "./changelog";
import { bumpCask, checkMinimumSystemVersion } from "./bump-cask";

// Run from the mac package root regardless of where we were invoked.
process.chdir(join(import.meta.dir, ".."));

const args = process.argv.slice(2).filter((arg) => arg !== "--");
const unknownArg = args.find((arg) => arg !== "--local");
if (unknownArg) die(`unknown option: ${unknownArg}`);
const localBuild = args.includes("--local");

// ---- config (override via env) -------------------------------------------
const PROJECT = "zshell.xcodeproj";
const SCHEME = "zshell";
const CONFIGURATION = process.env.CONFIGURATION ?? "Release";
const BUILD_DIR = process.env.BUILD_DIR ?? "build";
const UPDATES_DIR = join(BUILD_DIR, "updates");
const ARCHIVE_PATH = join(BUILD_DIR, "zshell.xcarchive");
const EXPORT_DIR = join(BUILD_DIR, "export");
const EXPORT_OPTIONS = process.env.EXPORT_OPTIONS ?? "scripts/ExportOptions.plist";
const NOTARY_PROFILE = process.env.NOTARY_PROFILE ?? "NOTARY";
// Codesigning identity for the .dmg itself. A partial name matches when there's
// a single Developer ID Application cert; override with the full name/SHA-1.
const ADHOC = process.env.CODE_SIGN_IDENTITY === "-" || process.env.SIGNING_MODE === "adhoc";
const SIGN_IDENTITY = process.env.SIGN_IDENTITY ?? (ADHOC ? "-" : "Developer ID Application");
// The GitHub Pages workflow that rebuilds the website, and the branch it deploys.
const SITE_WORKFLOW = process.env.SITE_WORKFLOW ?? "Web Pages";
const SITE_BRANCH = process.env.SITE_BRANCH ?? "main";
// Keep a broader recent window available for delta generation. Override to
// trade delta coverage for less download/storage.
const HISTORY_COUNT = Number(process.env.HISTORY_COUNT ?? "15");
if (!Number.isSafeInteger(HISTORY_COUNT) || HISTORY_COUNT < 0) {
  die("HISTORY_COUNT must be a non-negative integer.");
}
// Cap concurrent xcodebuild tasks so Release whole-module compiles don't pin
// every core. Default is half the logical CPUs (min 1).
const defaultBuildJobs = Math.max(1, Math.floor(cpus().length / 2));
const BUILD_JOBS = Number(process.env.BUILD_JOBS ?? defaultBuildJobs);
if (!Number.isSafeInteger(BUILD_JOBS) || BUILD_JOBS < 1) {
  die("BUILD_JOBS must be a positive integer.");
}
// When set, archive under utility QoS so interactive work keeps priority.
const BUILD_NICE = process.env.BUILD_NICE === "1";

process.env.DEVELOPER_DIR ??= "/Applications/Xcode-beta.app/Contents/Developer";
if (ADHOC) {
  // Build unsigned, then sign the complete exported bundle like Zisla's ad-hoc path.
  process.env.CODE_SIGNING_ALLOWED = "NO";
  process.env.CODE_SIGNING_REQUIRED = "NO";
}

need("xcodebuild");
need("ditto");
if (!localBuild && !ADHOC) need("xcrun");
need("plutil");
// Checked up front: publishing, the cask bump and the site redeploy all run
// after the build, too late to be useful as a prerequisite failure.
if (!localBuild) {
  need("git"); // tags the release, and pushes the cask bump
  need("gh");
  // A token that cannot create releases must not surface only after a
  // 20-minute notarized build.
  if ((await $`gh auth status`.nothrow().quiet()).exitCode !== 0) {
    die("gh is not authenticated — run `gh auth login` (needs repo scope).");
  }
}
need("create-dmg"); // brew install create-dmg
if (BUILD_NICE) need("taskpolicy");
if (!existsSync(EXPORT_OPTIONS)) {
  die(`export options not found: ${EXPORT_OPTIONS} (see RELEASING.md)`);
}

// ---- release helpers -----------------------------------------------------
/** Asset names on a release; empty when that release does not exist yet. */
async function releaseAssets(tag: string): Promise<string[]> {
  const out = await $`gh release view ${tag} --repo ${RELEASE_REPO} --json assets --jq ${".assets[].name"}`
    .nothrow()
    .quiet();
  return out.exitCode === 0 ? out.text().split("\n").filter(Boolean) : [];
}

/** Create `tag`'s release at the current commit unless it already exists. */
async function ensureRelease(
  tag: string,
  title: string,
  extra: string[],
): Promise<void> {
  const view = await $`gh release view ${tag} --repo ${RELEASE_REPO}`.nothrow().quiet();
  if (view.exitCode === 0) return;
  const sha = (await $`git rev-parse HEAD`.text()).trim();
  await $`gh release create ${tag} --repo ${RELEASE_REPO} --target ${sha} --title ${title} ${extra}`;
}

// ---- 1. archive ----------------------------------------------------------
const niceNote = BUILD_NICE ? ", utility QoS" : "";
say(`Archiving (${CONFIGURATION}, -jobs ${BUILD_JOBS}${niceNote})…`);
rmSync(ARCHIVE_PATH, { recursive: true, force: true });
rmSync(EXPORT_DIR, { recursive: true, force: true });
// -jobs limits concurrent build tasks (including swift-frontend). BUILD_NICE
// deprioritizes the whole archive so the machine stays responsive.
const archiveArgs = [
  "-project",
  PROJECT,
  "-scheme",
  SCHEME,
  "-configuration",
  CONFIGURATION,
  "-archivePath",
  ARCHIVE_PATH,
  "-jobs",
  String(BUILD_JOBS),
  "archive",
];
if (BUILD_NICE) {
  await $`taskpolicy -c utility xcodebuild ${archiveArgs}`;
} else {
  await $`xcodebuild ${archiveArgs}`;
}

// ---- 2. export or ad-hoc sign the app -------------------------------------
const app = join(EXPORT_DIR, "zshell.app");
if (ADHOC) {
  say("Preparing ad-hoc app…");
  const archivedApp = join(ARCHIVE_PATH, "Products/Applications/zshell.app");
  if (!existsSync(archivedApp)) die(`archived app not found at ${archivedApp}`);
  rmSync(EXPORT_DIR, { recursive: true, force: true });
  mkdirSync(EXPORT_DIR, { recursive: true });
  await $`ditto ${archivedApp} ${app}`;
  await $`codesign --force --deep --sign - ${app}`;
} else {
  say("Exporting Developer ID app…");
  await $`xcodebuild -exportArchive -archivePath ${ARCHIVE_PATH} -exportOptionsPlist ${EXPORT_OPTIONS} -exportPath ${EXPORT_DIR}`;
}

if (!existsSync(app)) die(`exported app not found at ${app}`);
const appPlist = join(app, "Contents/Info.plist");

// ---- 3. read the version from the built app ------------------------------
const version = (await $`plutil -extract CFBundleShortVersionString raw ${appPlist}`.text()).trim();
const build = (await $`plutil -extract CFBundleVersion raw ${appPlist}`.text()).trim();
if (!version) die("could not read CFBundleShortVersionString");
const zipName = `zshell-${version}.zip`; // Sparkle in-app update (deltas)
const dmgName = `zshell-${version}.dmg`; // notarized download
say(`Releasing zshell ${version} (build ${build})`);

// Don't clobber an already-published version unless forced.
if (!localBuild && process.env.FORCE !== "1") {
  if ((await releaseAssets(UPDATES_TAG)).includes(zipName)) {
    die(`${zipName} is already published — bump the version, or set FORCE=1.`);
  }
}

// ---- 4. build the DMG ----------------------------------------------------
// A staged folder holds only the app, so the disk image window is just the app
// + the Applications drop target.
say(`Building ${dmgName}…`);
const dmgPath = join(BUILD_DIR, dmgName);
const dmgStaging = join(BUILD_DIR, "dmg");
rmSync(dmgStaging, { recursive: true, force: true });
rmSync(dmgPath, { force: true });
mkdirSync(dmgStaging, { recursive: true });
await $`ditto ${app} ${join(dmgStaging, "zshell.app")}`;
// create-dmg can return non-zero from cosmetic Finder-scripting hiccups even
// when the image is fine, so check for the file instead of the exit code.
await $`create-dmg \
  --volname ${`zshell ${version}`} \
  --window-size 540 380 \
  --icon-size 128 \
  --icon ${"zshell.app"} 150 195 \
  --app-drop-link 390 195 \
  --hide-extension ${"zshell.app"} \
  --no-internet-enable \
  ${dmgPath} ${dmgStaging}`.nothrow();
if (!existsSync(dmgPath)) die("create-dmg did not produce a disk image");
await $`codesign --force --sign ${SIGN_IDENTITY} ${dmgPath}`;
if (localBuild) {
  say(`Done. Built and signed zshell ${version} locally; nothing was notarized or published:`);
  console.log(`     app      : ${app}`);
  console.log(`     download : ${dmgPath}`);
  process.exit(0);
}

// ---- 5. notarize + staple ------------------------------------------------
// Ad-hoc packages follow Zisla's free distribution path and cannot be notarized.
if (!ADHOC) {
  // Notarizing the DMG also notarizes the app's code hash, so we can staple both
  // the DMG (for downloads) and the app (for the Sparkle zip) from one submission.
  say(`Notarizing (profile: ${NOTARY_PROFILE})…`);
  await $`xcrun notarytool submit ${dmgPath} --keychain-profile ${NOTARY_PROFILE} --wait`;
  say("Stapling tickets…");
  await $`xcrun stapler staple ${dmgPath}`;
  await $`xcrun stapler staple ${app}`;
}

// ---- 6. package the Sparkle update (pull history first for deltas) --------
// The DMG is the download; Sparkle updates from this zip so it can build small
// binary deltas. UPDATES_DIR is a clean staging directory containing only the
// current archive and the recent history needed for those deltas.
rmSync(UPDATES_DIR, { recursive: true, force: true });
mkdirSync(UPDATES_DIR, { recursive: true });
if (process.env.NO_HISTORY !== "1") {
  say(
    `Selecting the ${HISTORY_COUNT} most recent archives from the ${UPDATES_TAG} release (for deltas)…`,
  );
  const published = await releaseAssets(UPDATES_TAG);
  const archiveVersion = (name: string) =>
    name.slice("zshell-".length, -".zip".length);
  const versionOrder = new Intl.Collator("en", { numeric: true });
  const recentArchives = published
    .filter((name) => /^zshell-.+\.zip$/.test(name) && name !== zipName)
    .sort((a, b) => versionOrder.compare(archiveVersion(b), archiveVersion(a)))
    .slice(0, HISTORY_COUNT);
  const historyFiles = [
    ...(published.includes("appcast.xml") ? ["appcast.xml"] : []),
    ...recentArchives,
  ];

  if (historyFiles.length > 0) {
    const patterns = historyFiles.flatMap((name) => ["--pattern", name]);
    await $`gh release download ${UPDATES_TAG} --repo ${RELEASE_REPO} ${patterns} --dir ${UPDATES_DIR} --clobber`;
  }
  say(
    recentArchives.length > 0
      ? `Pulled ${recentArchives.join(", ")}`
      : "No prior archives found",
  );
}
say(`Packaging ${zipName}…`);
await $`ditto -c -k --keepParent ${app} ${join(UPDATES_DIR, zipName)}`;

// Release notes: slice this version's section out of CHANGELOG.md next to the
// archive (as zshell-<version>.md). generate_appcast then attaches it as the
// update's <sparkle:releaseNotesLink>, which Sparkle renders in the prompt.
const changelog = join("..", "CHANGELOG.md");
const notesPath = join(UPDATES_DIR, `zshell-${version}.md`);
if (existsSync(changelog)) {
  const notes = extractReleaseNotes(await Bun.file(changelog).text(), version);
  if (notes) {
    await Bun.write(notesPath, `${notes}\n`);
    say(`Attached release notes for ${version}`);
  } else {
    say(`No "${version}" section in ${changelog} — releasing without notes`);
  }
} else {
  say(`No ${changelog} — releasing without notes`);
}

// ---- 7. sign + (re)generate the appcast ----------------------------------
say("Generating appcast…");
await generateAppcast(UPDATES_DIR, UPDATE_URL_PREFIX);

// ---- 8. publish to GitHub Releases ---------------------------------------
// The versioned release is what people download; the updates release is the flat
// store Sparkle resolves the appcast against. Only files that are not published
// yet get uploaded — the history pulled above already is — except appcast.xml,
// which every release rewrites.
say(`Publishing ${dmgName} on the v${version} release…`);
await ensureRelease(
  `v${version}`,
  `zshell ${version}`,
  existsSync(notesPath) ? ["--notes-file", notesPath] : ["--generate-notes"],
);
await $`gh release upload ${`v${version}`} --repo ${RELEASE_REPO} ${dmgPath} --clobber`;

say(`Uploading update archives to the ${UPDATES_TAG} release…`);
// Marked as a prerelease so this permanent feed holder never takes the "Latest
// release" badge away from an actual version.
await ensureRelease(UPDATES_TAG, "Sparkle update feed", [
  "--prerelease",
  "--notes",
  "Sparkle appcast and update archives. Downloads live on each version's own release.",
]);
const published = new Set(await releaseAssets(UPDATES_TAG));
const uploads = readdirSync(UPDATES_DIR, { withFileTypes: true })
  .filter(
    (entry) =>
      entry.isFile() &&
      (entry.name === "appcast.xml" || !published.has(entry.name)),
  )
  .map((entry) => join(UPDATES_DIR, entry.name));
await $`gh release upload ${UPDATES_TAG} --repo ${RELEASE_REPO} ${uploads} --clobber`;

// ---- 9. bump the Homebrew cask -------------------------------------------
// Last, because the cask's sha256 covers a DMG that must already be fetchable.
// The release is live at this point, so a failure here is a warning with a
// retry command, not a failed release.
if (process.env.NO_TAP !== "1") {
  say("Bumping the Homebrew cask…");
  try {
    await bumpCask(version, dmgPath);
    await checkMinimumSystemVersion(appPlist);
  } catch (error) {
    console.warn(
      `\x1b[1;33mwarning:\x1b[0m could not bump the cask: ${error instanceof Error ? error.message : error}\n` +
        `         retry with: bun scripts/bump-cask.ts ${version}`,
    );
  }
}

// ---- 10. redeploy the website --------------------------------------------
// The landing pages bake the advertised release in while they are prerendered
// (see web/src/lib/release.ts), so the appcast uploaded above only reaches
// visitors once Pages rebuilds. Same convention as the cask bump: the release
// is already live, so this is a warning with a retry command.
if (process.env.NO_SITE !== "1") {
  say("Redeploying the website…");
  try {
    await $`gh workflow run ${SITE_WORKFLOW} --ref ${SITE_BRANCH}`;
  } catch (error) {
    console.warn(
      `\x1b[1;33mwarning:\x1b[0m could not redeploy the website: ${error instanceof Error ? error.message : error}\n` +
        `         retry with: gh workflow run "${SITE_WORKFLOW}" --ref ${SITE_BRANCH}`,
    );
  }
}

say(`Done. zshell ${version} is live:`);
console.log(`     download : ${dmgUrl(version)}`);
console.log(`     update   : ${UPDATE_URL_PREFIX}${zipName}`);
console.log(`     feed     : ${APPCAST_URL}`);
