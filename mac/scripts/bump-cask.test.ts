import { expect, test } from "bun:test";
import { renderCask } from "./bump-cask";

test("cask preserves version/architecture interpolation and independent ZIP checksums", () => {
  const source = renderCask("0.1.0", "a".repeat(64), "b".repeat(64));
  expect(source).toContain('arch arm: "arm64", intel: "x86_64"');
  expect(source).toContain('sha256 arm:   "' + "a".repeat(64) + '"');
  expect(source).toContain('intel: "' + "b".repeat(64) + '"');
  expect(source).toContain('v#{version}/zshell-v#{version}-macOS-#{arch}.zip');
  expect(source).toContain('appcast-#{arch}.xml');
  expect(source).toContain('auto_updates true');
});

test("rejects partial hash data and non-release versions", () => {
  expect(() => renderCask("0.1.0", "", "b".repeat(64))).toThrow();
  expect(() => renderCask("0.1.0-preview.1", "a".repeat(64), "b".repeat(64))).toThrow();
});
