#!/usr/bin/env bun
import { createHash, createPublicKey, verify as verifySignature } from "node:crypto";
import { readFile } from "node:fs/promises";
import { userInfo } from "node:os";
import { join, resolve } from "node:path";

const REPOSITORY = "wzz6423/zshell";
const ARCHITECTURES = ["universal", "arm64", "x86_64"] as const;
type Host = "github" | "gitee";
type Asset = { name: string; path: string; sha256: string; size: number };
type RemoteAsset = { id: number; name: string; digest?: string; browser_download_url?: string };
type RemoteRelease = { id: number; tag_name: string; draft?: boolean; assets?: RemoteAsset[] | { links?: RemoteAsset[] } };
type Request = (input: string | URL, init?: RequestInit) => Promise<Response>;
export type PublishOptions = {
  directory: string;
  version: string;
  sourceCommit: string;
  notes?: string;
  publicKey?: string;
  credentials?: { github: string; gitee: string };
  request?: Request;
};
type Manifest = { packages: Asset[]; feeds: Record<Host, Asset[]> };
const digest = (bytes: Uint8Array): string => createHash("sha256").update(bytes).digest("hex");

async function asset(path: string): Promise<Asset> {
  const bytes = await readFile(path);
  if (!bytes.length) throw new Error(`Empty release asset: ${path}`);
  return { path, name: path.split("/").at(-1)!, size: bytes.length, sha256: digest(bytes) };
}

async function embeddedPublicKey(): Promise<string> {
  const plist = await readFile(new URL("../zshell/Info.plist", import.meta.url), "utf8");
  const match = plist.match(/<key>SUPublicEDKey<\/key>\s*<string>([^<]+)<\/string>/);
  if (!match) throw new Error("SUPublicEDKey missing from Info.plist");
  return match[1]!;
}

/** Reject incomplete, mismatched or unsigned inputs before contacting either host. */
export async function validateManifest(options: Pick<PublishOptions, "directory" | "version" | "publicKey">): Promise<Manifest> {
  if (!/^\d+\.\d+\.\d+$/.test(options.version)) throw new Error("Only stable semantic versions are supported");
  const publicBytes = Buffer.from(options.publicKey ?? await embeddedPublicKey(), "base64");
  if (publicBytes.length !== 32) throw new Error("Invalid Sparkle public key");
  const key = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), publicBytes]), format: "der", type: "spki" });
  const packages: Asset[] = [];
  const feeds: Record<Host, Asset[]> = { github: [], gitee: [] };
  for (const architecture of ARCHITECTURES) {
    const basename = `zshell-v${options.version}-macOS-${architecture}`;
    for (const extension of ["dmg", "zip"]) {
      const binary = await asset(join(options.directory, `${basename}.${extension}`));
      const checksum = await asset(`${binary.path}.sha256`);
      const recorded = (await readFile(checksum.path, "utf8")).trim();
      if (recorded !== `${binary.sha256}  ${binary.name}` && recorded !== `${binary.sha256} *${binary.name}`) {
        throw new Error(`SHA-256 mismatch or incorrect filename: ${checksum.name}`);
      }
      packages.push(binary, checksum);
    }
    const zip = packages.find(value => value.name === `${basename}.zip`)!;
    const zipBytes = await readFile(zip.path);
    for (const host of ["github", "gitee"] as const) {
      const feed = await asset(join(options.directory, host, architecture === "universal" ? "appcast.xml" : `appcast-${architecture}.xml`));
      const bytes = await readFile(feed.path);
      const text = bytes.toString("utf8");
      const signing = text.match(/<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]+={0,2})\nlength: (\d+)\n-->\n?$/);
      if (!signing || signing.index === undefined) throw new Error(`Missing signed appcast: ${host}/${feed.name}`);
      const contentLength = Number(signing[2]);
      if (contentLength !== Buffer.byteLength(text.slice(0, signing.index)) || !verifySignature(null, bytes.subarray(0, contentLength), key, Buffer.from(signing[1]!, "base64"))) {
        throw new Error(`Invalid appcast signature: ${host}/${feed.name}`);
      }
      const parsed = Bun.spawnSync(["xmllint", "--nonet", "--noout", "-"], { stdin: bytes, stdout: "pipe", stderr: "pipe" });
      if (parsed.exitCode !== 0 || /<!DOCTYPE|<!ENTITY/i.test(text)) throw new Error(`Invalid or unsafe XML: ${host}/${feed.name}`);
      const enclosures = [...text.matchAll(/<enclosure\b([^>]+)\/?\s*>/g)];
      if (enclosures.length !== 1 || [...text.matchAll(/<item(?:\s|>)/g)].length !== 1) throw new Error(`Expected one release enclosure: ${host}/${feed.name}`);
      const attributes = new Map([...enclosures[0]![1]!.matchAll(/([\w:.-]+)\s*=\s*["']([^"']*)["']/g)].map(match => [match[1], match[2]]));
      const expectedURL = `https://${host}.com/${REPOSITORY}/releases/download/v${options.version}/${zip.name}`;
      if (attributes.get("url") !== expectedURL || Number(attributes.get("length")) !== zip.size) throw new Error(`Wrong host, version, architecture or size: ${host}/${feed.name}`);
      if (!text.includes(`<sparkle:shortVersionString>${options.version}</sparkle:shortVersionString>`) && attributes.get("sparkle:shortVersionString") !== options.version) throw new Error(`Wrong release version: ${host}/${feed.name}`);
      const signature = attributes.get("sparkle:edSignature");
      if (!signature || !verifySignature(null, zipBytes, key, Buffer.from(signature, "base64"))) throw new Error(`Invalid ZIP signature: ${host}/${feed.name}`);
      feeds[host].push(feed);
    }
  }
  return { packages, feeds };
}

function commandSecret(command: string[]): string {
  const result = Bun.spawnSync(command, { stdout: "pipe", stderr: "pipe" });
  return result.exitCode === 0 ? result.stdout.toString().trim() : "";
}

export function loadCredentials(): { github: string; gitee: string } {
  const github = process.env.GH_TOKEN || process.env.GITHUB_TOKEN || commandSecret(["gh", "auth", "token"]);
  let gitee = process.env.GITEE_RELEASE_TOKEN ?? "";
  for (const account of new Set(["wzz6423", userInfo().username])) {
    if (!gitee) gitee = commandSecret(["security", "find-generic-password", "-s", "gitee.com.zisla.release-token", "-a", account, "-w"]);
  }
  if (!gitee) gitee = commandSecret(["security", "find-internet-password", "-s", "gitee.com", "-a", "wzz6423", "-w"]);
  if (!github) throw new Error("GitHub authentication missing; use gh auth login");
  if (!gitee) throw new Error("Gitee release token missing; configure GITEE_RELEASE_TOKEN or the gitee.com.zisla.release-token Keychain item");
  return { github, gitee };
}

export class ReleaseAPI {
  constructor(readonly host: Host, private token: string, private request: Request = fetch) {}
  private base = () => this.host === "github" ? "https://api.github.com" : "https://gitee.com/api/v5";
  private path = (suffix: string) => `/repos/${REPOSITORY}${suffix}`;

  async call(path: string, method = "GET", body?: unknown, allowMissing = false): Promise<any> {
    const response = await this.request(`${this.base()}${path}`, {
      method, headers: { Authorization: `Bearer ${this.token}`, Accept: "application/json", ...(body ? { "Content-Type": "application/json" } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    if (allowMissing && response.status === 404) return null;
    // Error bodies can echo request credentials; report only the endpoint and status.
    if (!response.ok) throw new Error(`${this.host} ${method} ${path}: HTTP ${response.status}`);
    return response.status === 204 ? null : response.json();
  }

  async preflight(sourceCommit?: string): Promise<{ login: string; repository: string }> {
    const identity = await this.call("/user");
    if (identity.login !== "wzz6423") throw new Error(`${this.host} authenticated account must be wzz6423`);
    const repository = await this.call(this.path(""));
    if (repository.full_name !== REPOSITORY || repository.private === true || repository.public === false) throw new Error(`${this.host} release repository must be public ${REPOSITORY}`);
    if (repository.permissions?.push === false) throw new Error(`${this.host} repository is read-only for the current account`);
    if (sourceCommit) await this.call(this.path(`/commits/${sourceCommit}`));
    return { login: identity.login, repository: repository.full_name };
  }

  getRelease(tag: string): Promise<RemoteRelease | null> {
    return this.call(this.path(`/releases/tags/${encodeURIComponent(tag)}`), "GET", undefined, true);
  }

  async ensureRelease(tag: string, commit: string, notes: string, permanent = false, stage = false): Promise<RemoteRelease> {
    const existing = await this.getRelease(tag);
    const body = { tag_name: tag, target_commitish: commit, name: permanent ? "Zshell update feed" : `Zshell ${tag}`, body: notes, prerelease: permanent, ...(this.host === "github" ? { draft: stage ? existing ? existing.draft ?? false : true : false, ...(!stage ? { make_latest: permanent ? "false" : "true" } : {}) } : {}) };
    return this.call(this.path(existing ? `/releases/${existing.id}` : "/releases"), existing ? "PATCH" : "POST", body);
  }

  async assets(release: RemoteRelease): Promise<RemoteAsset[]> {
    const result: RemoteAsset[] = [];
    for (let page = 1; ; page++) {
      const values = await this.call(this.path(`/releases/${release.id}/${this.host === "github" ? "assets" : "attach_files"}?per_page=100&page=${page}`));
      if (!Array.isArray(values)) throw new Error(`${this.host} invalid asset listing`);
      result.push(...values);
      if (values.length < 100) return result;
    }
  }

  private async remoteDigest(release: RemoteRelease, remote: RemoteAsset): Promise<string> {
    if (remote.digest?.startsWith("sha256:")) return remote.digest.slice(7);
    const path = this.host === "github" ? `/releases/assets/${remote.id}` : `/releases/${release.id}/attach_files/${remote.id}/download`;
    const response = await this.request(`${this.base()}${this.path(path)}`, { headers: { Authorization: `Bearer ${this.token}`, Accept: "application/octet-stream" } });
    if (!response.ok) throw new Error(`${this.host} asset ${remote.id} download: HTTP ${response.status}`);
    return digest(new Uint8Array(await response.arrayBuffer()));
  }

  async upload(release: RemoteRelease, local: Asset): Promise<void> {
    const all = await this.assets(release);
    const old = all.filter(value => value.name === local.name);
    let uploaded: RemoteAsset | undefined;
    for (const candidate of old) {
      if (await this.remoteDigest(release, candidate) === local.sha256) { uploaded = candidate; break; }
    }
    if (old.length === 1 && uploaded) return;
    // GitHub forbids duplicate names. Stage the replacement before deleting the old asset.
    const uploadName = this.host === "github" && old.length ? `${local.name}.pending-${local.sha256.slice(0, 12)}` : local.name;
    if (!uploaded && uploadName !== local.name) {
      const staged = all.find(value => value.name === uploadName);
      if (staged && await this.remoteDigest(release, staged) === local.sha256) uploaded = staged;
    }
    if (!uploaded) {
      const bytes = await readFile(local.path);
      if (digest(bytes) !== local.sha256) throw new Error(`Local release asset changed after validation: ${local.name}`);
      const content = new Blob([bytes]);
      const form = new FormData();
      form.set("file", content, uploadName);
      const url = this.host === "github"
        ? `https://uploads.github.com/repos/${REPOSITORY}/releases/${release.id}/assets?name=${encodeURIComponent(uploadName)}`
        : `${this.base()}${this.path(`/releases/${release.id}/attach_files`)}`;
      const response = await this.request(url, { method: "POST", headers: { Authorization: `Bearer ${this.token}`, ...(this.host === "github" ? { "Content-Type": "application/octet-stream" } : {}) }, body: this.host === "github" ? content : form });
      if (!response.ok) throw new Error(`${this.host} upload ${local.name}: HTTP ${response.status}`);
      uploaded = await response.json() as RemoteAsset;
    }
    if (await this.remoteDigest(release, uploaded) !== local.sha256) throw new Error(`${this.host} uploaded checksum mismatch: ${local.name}`);
    for (const previous of old) {
      if (previous.id === uploaded.id) continue;
      const suffix = this.host === "github" ? `/releases/assets/${previous.id}` : `/releases/${release.id}/attach_files/${previous.id}`;
      await this.call(this.path(suffix), "DELETE");
    }
    if (uploadName !== local.name) await this.call(this.path(`/releases/assets/${uploaded.id}`), "PATCH", { name: local.name });
    console.log(`${this.host}: uploaded ${local.name}`);
  }

  async verifyAssets(release: RemoteRelease, expected: Asset[]): Promise<void> {
    const remote = await this.assets(release);
    for (const local of expected) {
      const matches = remote.filter(value => value.name === local.name);
      if (matches.length !== 1 || await this.remoteDigest(release, matches[0]!) !== local.sha256) throw new Error(`${this.host} missing or mismatched published asset: ${local.name}`);
    }
  }
}

/** Read-only credential/repository check, usable before expensive packaging starts. */
export async function preflight(options: Partial<Pick<PublishOptions, "sourceCommit" | "credentials" | "request">> = {}): Promise<Record<Host, { login: string; repository: string }>> {
  const credentials = options.credentials ?? loadCredentials();
  return {
    github: await new ReleaseAPI("github", credentials.github, options.request).preflight(options.sourceCommit),
    gitee: await new ReleaseAPI("gitee", credentials.gitee, options.request).preflight(options.sourceCommit),
  };
}

async function prepare(options: PublishOptions): Promise<{ manifest: Manifest; github: ReleaseAPI; gitee: ReleaseAPI }> {
  if (!/^[a-f0-9]{40}$/.test(options.sourceCommit)) throw new Error("sourceCommit must be a full git commit hash");
  const manifest = await validateManifest(options);
  const credentials = options.credentials ?? loadCredentials();
  const github = new ReleaseAPI("github", credentials.github, options.request);
  const gitee = new ReleaseAPI("gitee", credentials.gitee, options.request);
  await github.preflight(options.sourceCommit);
  await gitee.preflight(options.sourceCommit);
  return { manifest, github, gitee };
}

export async function publishRelease(options: PublishOptions): Promise<void> {
  const { manifest, github, gitee } = await prepare(options);
  const tag = `v${options.version}`;
  const notesFile = Bun.file(join(options.directory, "notes.md"));
  const notes = options.notes ?? (await notesFile.exists() ? await notesFile.text() : `Zshell ${tag}`);
  const oldFeed = await gitee.getRelease("update-release");
  const oldVersion = await gitee.getRelease(tag);
  if (oldVersion && (!oldFeed || oldFeed.id > oldVersion.id)) throw new Error("Gitee update-release must predate the version release; repair release ordering explicitly before publishing");
  const feed = await gitee.ensureRelease("update-release", options.sourceCommit, "Signed Sparkle update feeds. Download applications from the versioned release.", true);
  const releases = {
    github: await github.ensureRelease(tag, options.sourceCommit, notes, false, true),
    gitee: await gitee.ensureRelease(tag, options.sourceCommit, notes),
  };
  // Both hosts receive all referenced binaries before either current feed changes.
  for (const host of ["github", "gitee"] as const) {
    const api = host === "github" ? github : gitee;
    for (const item of manifest.packages) await api.upload(releases[host], item);
    await api.verifyAssets(releases[host], manifest.packages);
  }
  for (const host of ["github", "gitee"] as const) {
    const api = host === "github" ? github : gitee;
    for (const item of manifest.feeds[host]) await api.upload(releases[host], item);
  }
  for (const item of manifest.feeds.gitee) await gitee.upload(feed, item);
  // A new GitHub release becomes latest only after its complete asset set exists.
  await github.ensureRelease(tag, options.sourceCommit, notes);
  await verifyPublishedRelease(options);
}

export async function verifyPublishedRelease(options: PublishOptions): Promise<void> {
  const { manifest, github, gitee } = await prepare(options);
  for (const host of ["github", "gitee"] as const) {
    const api = host === "github" ? github : gitee;
    const release = await api.getRelease(`v${options.version}`);
    if (!release) throw new Error(`${host} version release missing`);
    await api.verifyAssets(release, [...manifest.packages, ...manifest.feeds[host]]);
    if (host === "gitee") {
      const feed = await api.getRelease("update-release");
      if (!feed) throw new Error("Gitee update-release missing");
      if ((await api.assets(feed)).length !== 3) throw new Error("Gitee update-release must contain exactly three appcasts");
      await api.verifyAssets(feed, manifest.feeds.gitee);
    }
    const publicPrefix = host === "github" ? `https://github.com/${REPOSITORY}/releases/latest/download/` : `https://gitee.com/${REPOSITORY}/releases/download/update-release/`;
    for (const item of manifest.feeds[host]) {
      const response = await (options.request ?? fetch)(`${publicPrefix}${item.name}`);
      if (!response.ok || digest(new Uint8Array(await response.arrayBuffer())) !== item.sha256) throw new Error(`${host} public feed unavailable or differs: ${item.name}`);
    }
  }
  console.log("Verified both version releases and all six public signed feeds.");
}

if (import.meta.main) {
  const [mode, directory, version, sourceCommit] = process.argv.slice(2);
  if (!["--verify", "--publish"].includes(mode ?? "") || !directory || !version || !sourceCommit) {
    throw new Error("usage: bun scripts/publish-release.ts --verify|--publish <directory> <version> <source-commit>");
  }
  const options = { directory: resolve(directory), version, sourceCommit };
  await (mode === "--publish" ? publishRelease(options) : verifyPublishedRelease(options));
}
