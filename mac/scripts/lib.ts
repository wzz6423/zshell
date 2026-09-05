// Shared helpers for the release scripts.

/** Print a highlighted progress line. */
export const say = (msg: string): void =>
  console.log(`\n\x1b[1;34m==>\x1b[0m ${msg}`);

/** Print an error and exit non-zero. */
export const die = (msg: string): never => {
  console.error(`\x1b[1;31merror:\x1b[0m ${msg}`);
  process.exit(1);
};

/** Exit unless an executable is on PATH. */
export const need = (tool: string): void => {
  if (!Bun.which(tool)) die(`missing required tool: ${tool}`);
};

// ---- release origin ------------------------------------------------------
// Downloads and the Sparkle feed are GitHub Release assets, so shipping needs
// no domain or object store of its own. Each version's notarized DMG hangs off
// its own `v<version>` release, while UPDATES_TAG is one permanent release
// holding every update archive, delta and appcast.xml: Sparkle resolves each
// enclosure it may ever offer — including old versions' — against one prefix.
export const RELEASE_REPO = process.env.RELEASE_REPO ?? "wzz6423/zshell";
export const UPDATES_TAG = process.env.UPDATES_TAG ?? "updates";

/** Public URL prefix for the assets attached to one release tag. */
export const releasePrefix = (tag: string): string =>
  `https://github.com/${RELEASE_REPO}/releases/download/${tag}/`;

/** Base the appcast's enclosure and release-notes links are written against. */
export const UPDATE_URL_PREFIX =
  process.env.DOWNLOAD_URL_PREFIX ?? releasePrefix(UPDATES_TAG);
export const APPCAST_URL = `${UPDATE_URL_PREFIX}appcast.xml`;

/** The notarized download for `version`, attached to its own release. */
export const dmgUrl = (version: string): string =>
  `${releasePrefix(`v${version}`)}zshell-${version}.dmg`;
