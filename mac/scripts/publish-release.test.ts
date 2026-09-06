import { afterEach, expect, test } from "bun:test";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { publishRelease, ReleaseAPI, validateManifest } from "./publish-release";

const temporary: string[] = [];
afterEach(async () => { for (const path of temporary.splice(0)) await rm(path, { recursive: true }); });
const hash = (content: Uint8Array) => createHash("sha256").update(content).digest("hex");
const { privateKey, publicKey: key } = generateKeyPairSync("ed25519");
const publicKey = (key.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("base64");
const sourceCommit = "a".repeat(40);

function signedXML(xml: string): string {
  return `${xml}<!-- sparkle-signatures:\nedSignature: ${sign(null, Buffer.from(xml), privateKey).toString("base64")}\nlength: ${Buffer.byteLength(xml)}\n-->\n`;
}

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "zshell-publish-test-"));
  temporary.push(directory);
  for (const host of ["github", "gitee"]) await mkdir(join(directory, host));
  for (const architecture of ["universal", "arm64", "x86_64"]) {
    const name = `zshell-v0.1.0-macOS-${architecture}`;
    for (const extension of ["dmg", "zip"]) {
      const bytes = Buffer.from(`${architecture}:${extension}`);
      await writeFile(join(directory, `${name}.${extension}`), bytes);
      await writeFile(join(directory, `${name}.${extension}.sha256`), `${hash(bytes)}  ${name}.${extension}\n`);
    }
    const zip = await readFile(join(directory, `${name}.zip`));
    for (const host of ["github", "gitee"]) {
      const xml = `<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:shortVersionString>0.1.0</sparkle:shortVersionString><enclosure url="https://${host}.com/wzz6423/zshell/releases/download/v0.1.0/${name}.zip" length="${zip.length}" sparkle:edSignature="${sign(null, zip, privateKey).toString("base64")}"/></item></channel></rss>\n`;
      await writeFile(join(directory, host, architecture === "universal" ? "appcast.xml" : `appcast-${architecture}.xml`), signedXML(xml));
    }
  }
  return { directory, version: "0.1.0", publicKey, sourceCommit };
}

async function changeFeed(directory: string, change: (xml: string) => string) {
  const path = join(directory, "gitee", "appcast-arm64.xml");
  const xml = (await readFile(path, "utf8")).split("<!-- sparkle-signatures:")[0]!;
  await writeFile(path, signedXML(change(xml)));
}

test("accepts all twelve packages/checksums and six cryptographically signed appcasts", async () => {
  const manifest = await validateManifest(await fixture());
  expect(manifest.packages).toHaveLength(12);
  expect(manifest.feeds.github).toHaveLength(3);
  expect(manifest.feeds.gitee).toHaveLength(3);
});

test("rejects incomplete manifests before any network request or mutation", async () => {
  const options = await fixture();
  await rm(join(options.directory, "zshell-v0.1.0-macOS-arm64.zip"));
  let calls = 0;
  await expect(publishRelease({ ...options, credentials: { github: "stub", gitee: "stub" }, request: async () => { calls++; throw new Error("unexpected network"); } })).rejects.toThrow();
  expect(calls).toBe(0);
});

test("rejects checksum contents, filenames and binary tampering", async () => {
  const options = await fixture();
  await writeFile(join(options.directory, "zshell-v0.1.0-macOS-arm64.dmg.sha256"), `${"0".repeat(64)}  zshell-v0.1.0-macOS-arm64.dmg\n`);
  await expect(validateManifest(options)).rejects.toThrow("SHA-256 mismatch");
});

for (const [name, replace] of [
  ["cross-host", (xml: string) => xml.replace("https://gitee.com", "https://github.com")],
  ["cross-architecture", (xml: string) => xml.replace("macOS-arm64.zip", "macOS-x86_64.zip")],
  ["permanent-tag download", (xml: string) => xml.replace("download/v0.1.0/", "download/update-release/")],
] as const) {
  test(`rejects ${name} feeds even with a valid XML signature`, async () => {
    const options = await fixture();
    await changeFeed(options.directory, replace);
    await expect(validateManifest(options)).rejects.toThrow("Wrong host, version, architecture or size");
  });
}

test("rejects modified appcast signature", async () => {
  const options = await fixture();
  const path = join(options.directory, "gitee", "appcast-arm64.xml");
  await writeFile(path, (await readFile(path, "utf8")).replace("<channel>", "<channel> "));
  await expect(validateManifest(options)).rejects.toThrow("Invalid appcast signature");
});

test("rejects ZIP signature even when enclosing XML is signed correctly", async () => {
  const options = await fixture();
  await changeFeed(options.directory, xml => xml.replace(/sparkle:edSignature="[^"]+"/, `sparkle:edSignature="${Buffer.alloc(64).toString("base64")}"`));
  await expect(validateManifest(options)).rejects.toThrow("Invalid ZIP signature");
});

test("both host identities and source commits are checked before the first write", async () => {
  const options = await fixture();
  const calls: string[] = [];
  await expect(publishRelease({ ...options, credentials: { github: "stub", gitee: "stub" }, request: async (input, init) => {
    calls.push(`${init?.method ?? "GET"} ${input}`);
    if (String(input).endsWith("/user")) return Response.json({ login: String(input).includes("gitee") ? "wrong-account" : "wzz6423" });
    if (String(input).includes("/commits/")) return Response.json({ sha: sourceCommit });
    return Response.json({ full_name: "wzz6423/zshell", private: false, permissions: { push: true } });
  } })).rejects.toThrow("authenticated account");
  expect(calls).toHaveLength(4);
  expect(calls.every(value => value.startsWith("GET "))).toBe(true);
});

test("Gitee existing release PATCH includes tag_name and uses independent attachments", async () => {
  const events: { url: string; init?: RequestInit }[] = [];
  const content = Buffer.from("new attachment");
  const path = join((await fixture()).directory, "upload.dmg");
  await writeFile(path, content);
  const api = new ReleaseAPI("gitee", "secret-stub", async (input, init) => {
    const url = String(input);
    events.push({ url, init });
    if (url.includes("/tags/")) return Response.json({ id: 42, tag_name: "v0.1.0" });
    if (url.endsWith("/attach_files") && init?.method === "POST") return Response.json({ id: 8, name: "upload.dmg" });
    if (url.endsWith("/download")) return new Response(content);
    if (url.includes("/attach_files?")) return Response.json([{ id: 7, name: "upload.dmg", digest: `sha256:${"0".repeat(64)}` }]);
    if (init?.method === "DELETE") return new Response(null, { status: 204 });
    return Response.json({ id: 42, tag_name: "v0.1.0" });
  });
  const release = await api.ensureRelease("v0.1.0", sourceCommit, "notes");
  await api.upload(release, { name: "upload.dmg", path, sha256: hash(content), size: content.length });
  const patch = events.find(event => event.init?.method === "PATCH")!;
  expect(JSON.parse(String(patch.init?.body)).tag_name).toBe("v0.1.0");
  const uploadIndex = events.findIndex(event => event.init?.method === "POST");
  const deleteIndex = events.findIndex(event => event.init?.method === "DELETE");
  expect(uploadIndex).toBeLessThan(deleteIndex);
  expect(events[uploadIndex]!.init!.body).toBeInstanceOf(FormData);
  expect(events[deleteIndex]!.url).toEndWith("/releases/42/attach_files/7");
  expect(events.every(event => !event.url.includes("secret-stub"))).toBe(true);
});

test("matching existing assets are not uploaded or deleted", async () => {
  const calls: string[] = [];
  const api = new ReleaseAPI("github", "stub", async (url, init) => {
    calls.push(init?.method ?? "GET");
    return Response.json([{ id: 1, name: "appcast.xml", digest: `sha256:${"a".repeat(64)}` }]);
  });
  await api.upload({ id: 2, tag_name: "v0.1.0" }, { name: "appcast.xml", path: "unused", sha256: "a".repeat(64), size: 1 });
  expect(calls).toEqual(["GET"]);
});

test("resumes a verified GitHub staged upload without uploading or touching legacy assets", async () => {
  const calls: string[] = [];
  const sha256 = "a".repeat(64);
  const api = new ReleaseAPI("github", "stub", async (url, init) => {
    calls.push(`${init?.method ?? "GET"} ${url}`);
    if (init?.method === "DELETE") return new Response(null, { status: 204 });
    if (init?.method === "PATCH") return Response.json({ id: 2, name: "appcast.xml" });
    return Response.json([
      { id: 1, name: "appcast.xml", digest: `sha256:${"b".repeat(64)}` },
      { id: 2, name: `appcast.xml.pending-${sha256.slice(0, 12)}`, digest: `sha256:${sha256}` },
      { id: 3, name: "zshell-0.1.0.zip", digest: "sha256:legacy" },
    ]);
  });
  await api.upload({ id: 42, tag_name: "v0.1.0" }, { name: "appcast.xml", path: "unused", sha256, size: 1 });
  expect(calls.some(value => value.startsWith("POST"))).toBe(false);
  expect(calls.filter(value => value.startsWith("DELETE"))).toEqual(["DELETE https://api.github.com/repos/wzz6423/zshell/releases/assets/1"]);
  expect(calls.at(-1)).toBe("PATCH https://api.github.com/repos/wzz6423/zshell/releases/assets/2");
});

test("API failures do not expose server error bodies or credentials", async () => {
  const api = new ReleaseAPI("gitee", "secret-stub", async () => new Response("token=secret-stub", { status: 401 }));
  await expect(api.getRelease("v0.1.0")).rejects.toThrow("gitee GET /repos/wzz6423/zshell/releases/tags/v0.1.0: HTTP 401");
});

test("publishing creates Gitee feed first, uploads both binary sets before feeds, and preserves legacy assets", async () => {
  const options = await fixture();
  const events: string[] = [];
  type FakeAsset = { id: number; name: string; digest: string; content: Buffer };
  type FakeRelease = { id: number; tag_name: string; draft: boolean; assets: FakeAsset[] };
  const releases: Record<string, FakeRelease[]> = { github: [{ id: 1, tag_name: "v0.1.0", draft: false, assets: [{ id: 10, name: "zshell-0.1.0.zip", digest: "sha256:old", content: Buffer.from("old Sparkle download") }] }], gitee: [] };
  let nextID = 100;
  await publishRelease({ ...options, notes: "release notes", credentials: { github: "stub", gitee: "stub" }, request: async (input, init) => {
    const url = new URL(input);
    const host = url.hostname.includes("github") ? "github" : "gitee";
    const method = init?.method ?? "GET";
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined;
    if (url.pathname.endsWith("/user")) return Response.json({ login: "wzz6423" });
    if (url.pathname.endsWith("/repos/wzz6423/zshell")) return Response.json({ full_name: "wzz6423/zshell", public: true });
    if (url.pathname.includes("/commits/")) return Response.json({ sha: sourceCommit });
    const tag = url.pathname.match(/\/releases\/tags\/([^/]+)$/)?.[1];
    if (tag) {
      const release = releases[host]!.find(value => value.tag_name === tag);
      return release ? Response.json(release) : new Response(null, { status: 404 });
    }
    if (url.pathname.endsWith("/releases") && method === "POST") {
      events.push(`${host}:create:${body.tag_name}`);
      const release = { id: nextID++, tag_name: body.tag_name, draft: body.draft ?? false, assets: [] };
      releases[host]!.push(release);
      return Response.json(release);
    }
    const releaseID = Number(url.pathname.match(/\/releases\/(\d+)/)?.[1]);
    const release = releases[host]!.find(value => value.id === releaseID);
    if (release && /\/releases\/\d+$/.test(url.pathname) && method === "PATCH") {
      events.push(`${host}:patch:${body.tag_name}:${body.make_latest ?? "staged"}`);
      release.draft = body.draft ?? false;
      return Response.json(release);
    }
    if (release && /\/(assets|attach_files)$/.test(url.pathname)) {
      if (method === "GET") return Response.json(release.assets);
      if (method === "POST") {
        const file = init!.body instanceof FormData ? init!.body.get("file") as File : init!.body as Blob;
        const name = url.searchParams.get("name") ?? (file as File).name;
        const content = Buffer.from(await file.arrayBuffer());
        const uploaded = { id: nextID++, name, digest: `sha256:${hash(content)}`, content };
        release.assets.push(uploaded);
        events.push(`${host}:upload:${release.tag_name}:${name}`);
        return Response.json(uploaded);
      }
    }
    if (url.pathname.includes("/releases/latest/download/") || url.pathname.includes("/releases/download/update-release/")) {
      const feedRelease = releases[host]!.find(value => value.tag_name === (host === "github" ? "v0.1.0" : "update-release"))!;
      const item = feedRelease.assets.find(value => value.name === url.pathname.split("/").at(-1))!;
      return new Response(item.content);
    }
    throw new Error(`Unhandled stub: ${method} ${url}`);
  } });
  expect(events.indexOf("gitee:create:update-release")).toBeLessThan(events.indexOf("gitee:create:v0.1.0"));
  const firstFeed = events.findIndex(value => value.includes(":upload:") && value.endsWith(".xml"));
  expect(events.slice(0, firstFeed).filter(value => value.includes(":upload:"))).toHaveLength(24);
  expect(releases.github![0]!.assets).toHaveLength(16);
  expect(releases.github![0]!.assets.some(value => value.name === "zshell-0.1.0.zip")).toBe(true);
  expect(releases.gitee!.find(value => value.tag_name === "v0.1.0")!.assets).toHaveLength(15);
  expect(releases.gitee!.find(value => value.tag_name === "update-release")!.assets).toHaveLength(3);
  expect(events.at(-1)).toBe("github:patch:v0.1.0:true");
});
