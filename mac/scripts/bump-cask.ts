#!/usr/bin/env bun
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { validateManifest } from "./publish-release";

export function renderCask(version: string, arm64: string, x86_64: string): string {
  if (!/^\d+\.\d+\.\d+$/.test(version) || ![arm64, x86_64].every(hash => /^[a-f0-9]{64}$/.test(hash))) {
    throw new Error("Cask version and both SHA-256 values must be valid");
  }
  return `cask "zshell" do
  arch arm: "arm64", intel: "x86_64"

  version "${version}"
  sha256 arm:   "${arm64}",
         intel: "${x86_64}"

  url "https://github.com/wzz6423/zshell/releases/download/v#{version}/zshell-v#{version}-macOS-#{arch}.zip"
  name "Zshell"
  desc "Native terminal workspace with projects, panes, editor, and Git tools"
  homepage "https://wzz6423.github.io/zshell/"

  livecheck do
    url "https://github.com/wzz6423/zshell/releases/latest/download/appcast-#{arch}.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sequoia

  app "zshell.app"

  zap trash: [
    "~/.config/zshell",
    "~/Library/Caches/sh.zshell",
    "~/Library/Preferences/sh.zshell.plist",
    "~/Library/Saved Application State/sh.zshell.savedState",
  ]

  caveats <<~EOS
    Zshell requires macOS 15.6 or later.

    Zshell uses a stable self-signed certificate and is not notarized. If macOS
    blocks the first launch, open System Settings > Privacy & Security and choose
    "Open Anyway" after trying to open Zshell. Sparkle verifies subsequent updates.
  EOS
end
`;
}

/** Prepare the reviewed recipe without committing or pushing the shared tap. */
export async function bumpCask(version: string, directory: string, caskPath: string): Promise<void> {
  const manifest = await validateManifest({ directory, version });
  const hashes = ["arm64", "x86_64"].map(arch => {
    const name = `zshell-v${version}-macOS-${arch}.zip`;
    const entry = manifest.packages.find(asset => asset.name === name);
    if (!entry) throw new Error(`Missing validated archive: ${name}`);
    return entry.sha256;
  });
  mkdirSync(dirname(caskPath), { recursive: true });
  await Bun.write(caskPath, renderCask(version, hashes[0]!, hashes[1]!));
  console.log(`Prepared ${caskPath}; submit this recipe and its tap copy as PRs after verifying both release hosts.`);
}

if (import.meta.main) {
  const mac = join(import.meta.dir, "..");
  const version = process.argv[2] ?? readFileSync(join(mac, "zshell.xcodeproj/project.pbxproj"), "utf8").match(/MARKETING_VERSION = ([^;]+);/)?.[1];
  if (!version) throw new Error("Version is required");
  const directory = resolve(process.argv[3] ?? join(mac, `build/release-v${version}`));
  await bumpCask(version, directory, resolve(process.env.TAP_CASK ?? join(mac, "../Casks/zshell.rb")));
}
