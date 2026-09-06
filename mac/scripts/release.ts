#!/usr/bin/env bun
import { $ } from "bun";
import { createHash, createPrivateKey, createPublicKey } from "node:crypto";
import { chmodSync, closeSync, constants, existsSync, fstatSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { dirname, join, resolve } from "node:path";
import { extractReleaseNotes } from "./changelog";
import { findGenerateAppcast } from "./generate-appcast";
import { die, need, say } from "./lib";

export const architectures = ["arm64", "x86_64", "universal"] as const;
export type Architecture = (typeof architectures)[number];
export const packageName = (version: string, arch: Architecture) => `zshell-v${version}-macOS-${arch}`;
export const feedName = (arch: Architecture) => arch === "universal" ? "appcast.xml" : `appcast-${arch}.xml`;

export function validateRelease(version: string, build: string, identity: string): void {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error("A stable semantic version is required");
  if (!/^[1-9]\d*$/.test(build)) throw new Error("A positive integer build number is required");
  if (!identity.trim() || identity === "-") throw new Error("Stable releases require a certificate identity, not ad-hoc signing");
}

export function verifyKeyPair(keyPath: string, publicKey: string): void {
  const descriptor = openSync(keyPath, constants.O_RDONLY | constants.O_NOFOLLOW);
  let encoded: string;
  try {
    const metadata = fstatSync(descriptor);
    if (!metadata.isFile() || (metadata.mode & 0o077) !== 0) throw new Error("Sparkle private key permissions must be 600 on a regular file");
    encoded = readFileSync(descriptor, "utf8");
  } finally { closeSync(descriptor); }
  const key = Buffer.from(encoded.trim(), "base64");
  if (key.length !== 32 && key.length !== 64) throw new Error("Invalid Sparkle private key format");
  const privateKey = createPrivateKey({ key: Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"), key.subarray(0, 32),
  ]), format: "der", type: "pkcs8" });
  const derived = createPublicKey(privateKey.export({ format: "pem", type: "pkcs8" })).export({ format: "der", type: "spki" }).subarray(-32);
  if (!derived.equals(Buffer.from(publicKey, "base64"))) throw new Error("Sparkle private key does not match the app public key");
}

function files(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? files(path) : entry.isFile() ? [path] : [];
  });
}

function isMachO(path: string): boolean {
  const data = readFileSync(path);
  return data.length >= 4 && [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].includes(data.readUInt32BE());
}

async function verifyArchitecture(app: string, arch: Architecture): Promise<void> {
  const expected = arch === "universal" ? ["arm64", "x86_64"] : [arch];
  for (const path of files(app).filter(isMachO)) {
    const actual = (await $`lipo -archs ${path}`.quiet().text()).trim().split(/\s+/).sort();
    if (actual.join(" ") !== [...expected].sort().join(" ")) throw new Error(`Wrong architecture in ${path}: ${actual.join(" ")}`);
  }
}

async function main(): Promise<void> {
  process.chdir(join(import.meta.dir, ".."));
  const args = process.argv.slice(2).filter((arg) => arg !== "--");
  if (args.some((arg) => !["--local", "--package-only"].includes(arg))) die("usage: release.ts [--local] [--package-only]");
  process.env.DEVELOPER_DIR ??= "/Applications/Xcode-beta.app/Contents/Developer";
  for (const command of ["xcodebuild", "ditto", "codesign", "lipo", "hdiutil", "git"]) need(command);
  const settings = readFileSync("zshell.xcodeproj/project.pbxproj", "utf8");
  const version = settings.match(/MARKETING_VERSION = ([^;]+);/)?.[1] ?? "";
  const build = settings.match(/CURRENT_PROJECT_VERSION = ([^;]+);/)?.[1] ?? "";
  const identity = process.env.CODE_SIGN_IDENTITY ?? "zshell Release Signing";
  validateRelease(version, build, identity);
  const keychain = process.env.CODE_SIGN_KEYCHAIN ?? join(homedir(), "Library/Keychains/zshell-release-signing.keychain-db");
  if (!existsSync(keychain)) die("Release signing keychain missing; run setup-release-signing.py once");
  const keyPath = process.env.SPARKLE_ED_KEY_FILE ?? die("SPARKLE_ED_KEY_FILE must point to the existing private update key");
  const publicKey = (await $`plutil -extract SUPublicEDKey raw zshell/Info.plist`.quiet().text()).trim();
  verifyKeyPair(keyPath, publicKey);
  const generator = await findGenerateAppcast() ?? die("Sparkle generate_appcast is missing; set SPARKLE_BIN");
  const signUpdate = join(dirname(generator), "sign_update");
  const passwordResult = await $`security find-generic-password -a ${userInfo().username} -s sh.zshell.release-signing-keychain -w`.quiet().nothrow();
  if (passwordResult.exitCode !== 0) die("Release keychain password is unavailable");
  const unlocked = Bun.spawn(["security", "unlock-keychain", keychain], { stdin: passwordResult.stdout, stdout: "ignore", stderr: "ignore" });
  if (await unlocked.exited !== 0) die("Unable to unlock the release signing keychain");

  const sourceCommit = (await $`git rev-parse HEAD`.quiet().text()).trim();
  const output = resolve(process.env.RELEASE_OUTPUT_DIRECTORY ?? `build/release-v${version}`);
  const archive = join(output, ".archive/zshell.xcarchive");
  const archivedApp = join(archive, "Products/Applications/zshell.app");
  const sourceRecord = join(output, ".archive/source-commit");
  mkdirSync(output, { recursive: true });
  if (!args.includes("--local")) {
    const { preflight } = await import("./publish-release");
    await preflight();
  }
  if (!args.includes("--package-only")) {
    if (existsSync(archive)) die("Archive already exists; use --package-only to resume the same commit or a fresh RELEASE_OUTPUT_DIRECTORY");
    const jobs = Number(process.env.BUILD_JOBS ?? "2");
    if (!Number.isSafeInteger(jobs) || jobs < 1) die("BUILD_JOBS must be positive");
    say(`Archiving Release ${version} (${build}), arm64 + x86_64`);
    await $`xcodebuild -project zshell.xcodeproj -scheme zshell -configuration Release -archivePath ${archive} -derivedDataPath ${join(output, ".derived-data")} -jobs ${String(jobs)} ${"ARCHS=arm64 x86_64"} ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive`;
    await Bun.write(sourceRecord, sourceCommit);
  } else if (!existsSync(archivedApp) || !existsSync(sourceRecord) || readFileSync(sourceRecord, "utf8") !== sourceCommit) {
    die("Resume requires an archive from the current source commit");
  }
  const plist = join(archivedApp, "Contents/Info.plist");
  for (const [key, value] of Object.entries({ CFBundleIdentifier: "sh.zshell", CFBundleShortVersionString: version, CFBundleVersion: build, CFBundleIconName: "AppIcon", SURequireSignedFeed: "true" })) {
    if ((await $`plutil -extract ${key} raw ${plist}`.quiet().text()).trim() !== value) die(`Release metadata mismatch: ${key}`);
  }
  await verifyArchitecture(archivedApp, "universal");
  const notes = extractReleaseNotes(readFileSync("../CHANGELOG.md", "utf8"), version);
  if (!notes) die(`Missing changelog section for ${version}`);
  await Bun.write(join(output, "notes.md"), notes + "\n\nRequires macOS 15.6+. Stable self-signed certificate; not Apple-notarized. If blocked on first launch, choose System Settings > Privacy & Security > Open Anyway. Sparkle verifies signed appcasts and ZIP archives.\n");
  const requirements: string[] = [];
  for (const arch of architectures) {
    say(`Packaging ${arch}`);
    const stage = join(output, ".staging", arch);
    rmSync(stage, { recursive: true, force: true });
    mkdirSync(stage, { recursive: true });
    const app = join(stage, "zshell.app");
    await $`ditto ${archivedApp} ${app}`;
    if (arch !== "universal") {
      // Thin every nested executable too; a thin launcher with fat frameworks is not a thin package.
      for (const binary of files(app).filter(isMachO)) {
        const mode = lstatSync(binary).mode;
        await $`lipo ${binary} -thin ${arch} -output ${binary + ".thin"}`.quiet();
        renameSync(binary + ".thin", binary);
        chmodSync(binary, mode);
      }
    }
    await $`codesign --force --deep --sign ${identity} --keychain ${keychain} ${app}`;
    await $`codesign --verify --deep --strict --all-architectures ${app}`;
    const requirement = (await $`codesign -d -r- ${app}`.quiet().text()).split("designated => ")[1]?.trim();
    if (!requirement?.includes("certificate") || requirement.includes("cdhash")) die("Release signing did not produce a stable certificate requirement");
    requirements.push(requirement);
    await verifyArchitecture(app, arch);
    if (!existsSync(join(app, "Contents/Frameworks/Sparkle.framework/Updater.app/Contents/MacOS/Updater"))) die("Sparkle installer is missing");
    const base = packageName(version, arch);
    const zip = join(output, `${base}.zip`);
    const dmg = join(output, `${base}.dmg`);
    for (const path of [zip, dmg]) if (existsSync(path)) rmSync(path);
    await $`ditto -c -k --keepParent ${app} ${zip}`;
    await $`ln -s /Applications ${join(stage, "Applications")}`;
    await $`hdiutil create -volname zshell -srcfolder ${stage} -format UDZO -ov ${dmg}`;
    await $`codesign --force --sign ${identity} --keychain ${keychain} ${dmg}`;
    await $`hdiutil verify ${dmg}`.quiet();
    for (const path of [zip, dmg]) {
      const hash = createHash("sha256").update(readFileSync(path)).digest("hex");
      await Bun.write(`${path}.sha256`, `${hash}  ${path.split("/").at(-1)}\n`);
    }
    const feedStage = join(output, ".feeds", arch);
    rmSync(feedStage, { recursive: true, force: true });
    mkdirSync(feedStage, { recursive: true });
    await $`ln ${zip} ${join(feedStage, `${base}.zip`)}`;
    for (const host of ["github", "gitee"]) {
      const feedDirectory = join(output, host);
      mkdirSync(feedDirectory, { recursive: true });
      const feed = join(feedDirectory, feedName(arch));
      if (existsSync(feed)) rmSync(feed);
      await $`${generator} --ed-key-file ${keyPath} --download-url-prefix ${`https://${host}.com/wzz6423/zshell/releases/download/v${version}/`} -o ${feed} ${feedStage}`;
      await $`${signUpdate} --verify --ed-key-file ${keyPath} ${feed}`;
    }
  }
  if (new Set(requirements).size !== 1) die("Architecture packages have different designated requirements");
  await Bun.write(join(output, "source.json"), JSON.stringify({ version, build, sourceCommit, architectures }, null, 2) + "\n");
  const { validateManifest, publishRelease } = await import("./publish-release");
  await validateManifest({ directory: output, version });
  if (!args.includes("--local")) await publishRelease({ directory: output, version, sourceCommit, notes: readFileSync(join(output, "notes.md"), "utf8") });
  say(`All three architecture packages validated at ${output}`);
  say("Submit the cask and website changes as PRs after both release hosts verify successfully.");
}

if (import.meta.main) await main();
