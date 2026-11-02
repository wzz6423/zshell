import { describe, expect, test } from "bun:test";
import { createPrivateKey, createPublicKey, randomBytes } from "node:crypto";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { architectures, feedName, packageName, validateRelease, verifyCodeSignatures, verifyKeyPair } from "./release";

describe("stable release preflight", () => {
  test("refuses ad-hoc and invalid release metadata", () => {
    expect(() => validateRelease("0.1.0", "3", "zshell Release Signing")).not.toThrow();
    for (const args of [["0.1.0", "3", "-"], ["0.1.0", "0", "cert"], ["0.1.0-preview.1", "3", "cert"], ["../0.1.0", "3", "cert"]]) {
      expect(() => validateRelease(args[0]!, args[1]!, args[2]!)).toThrow();
    }
  });
  test("one distinct package and feed per architecture", () => {
    expect(new Set(architectures.map(arch => packageName("0.1.0", arch))).size).toBe(3);
    expect(architectures.map(feedName)).toEqual(["appcast-arm64.xml", "appcast-x86_64.xml", "appcast.xml"]);
  });
  test("rejects wrong keys and unsafe private-key permissions before building", () => {
    const dir = mkdtempSync(join(tmpdir(), "zshell-key-test-"));
    try {
      const seed = randomBytes(32);
      const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]), format: "der", type: "pkcs8" });
      const publicKey = createPublicKey(privateKey.export({ format: "pem", type: "pkcs8" })).export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
      const path = join(dir, "private-key");
      writeFileSync(path, seed.toString("base64"), { mode: 0o600 });
      expect(() => verifyKeyPair(path, publicKey)).not.toThrow();
      expect(() => verifyKeyPair(path, randomBytes(32).toString("base64"))).toThrow("does not match");
      const link = join(dir, "linked-key");
      symlinkSync(path, link);
      expect(() => verifyKeyPair(link, publicKey)).toThrow();
      chmodSync(path, 0o644);
      expect(() => verifyKeyPair(path, publicKey)).toThrow("permissions");
    } finally { rmSync(dir, { recursive: true }); }
  });
});

test.skipIf(process.platform !== "darwin")("rejects an unsigned executable hidden from deep bundle verification", async () => {
  const dir = mkdtempSync(join(tmpdir(), "zshell-signature-test-"));
  try {
    const app = join(dir, "Fixture.app");
    mkdirSync(join(app, "Contents/MacOS"), { recursive: true });
    mkdirSync(join(app, "Contents/Resources"), { recursive: true });
    copyFileSync("/usr/bin/true", join(app, "Contents/MacOS/Fixture"));
    writeFileSync(join(app, "Contents/Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>sh.zshell.signature-test</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>`);
    const server = join(app, "Contents/Resources/zshell-server");
    const run = (args: string[]) => {
      const result = Bun.spawnSync(args, { stdout: "pipe", stderr: "pipe" });
      if (result.exitCode !== 0) throw new Error(result.stderr.toString());
    };
    run(["lipo", "/usr/bin/true", "-thin", "x86_64", "-output", server]);
    run(["codesign", "--remove-signature", server]);
    run(["codesign", "--force", "--deep", "--sign", "-", app]);
    run(["codesign", "--verify", "--deep", "--strict", "--all-architectures", app]);
    await expect(verifyCodeSignatures(app)).rejects.toThrow();
    run(["codesign", "--force", "--sign", "-", server]);
    run(["codesign", "--force", "--deep", "--sign", "-", app]);
    await verifyCodeSignatures(app);
  } finally { rmSync(dir, { recursive: true }); }
});
