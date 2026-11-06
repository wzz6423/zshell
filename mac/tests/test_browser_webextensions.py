"""Exercise production WebExtension installation and BrowserTab/WebKit runtimes.

Build Debug first and set ZSHELL_TEST_DERIVED_DATA. Extension resources, browser
stores, servers, preferences, probe binaries and caches use a disposable HOME.
"""

import http.server
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import threading
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug"))
PRODUCTS = BUILD / "Build/Products/Debug"
LIBRARY = PRODUCTS / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"


class Page(http.server.BaseHTTPRequestHandler):
    requests = []

    def do_GET(self):
        self.requests.append(self.path)
        body = b"served" if self.path.startswith("/extension-network") else b"<!doctype html><title>Extension fixture</title><body><p>Page</p></body>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


if not LIBRARY.is_file():
    raise SystemExit(f"Build Debug in {BUILD} first")

with tempfile.TemporaryDirectory(prefix="zshell-webextensions-", dir="/tmp") as name:
    temporary = Path(name)
    contents = temporary / "ExtensionsTest.app/Contents"
    binary = contents / "MacOS/extensions-test"
    binary.parent.mkdir(parents=True)
    info = plistlib.loads((LIBRARY.parents[1] / "Info.plist").read_bytes())
    domain = "sh.zshell.webextensions-test." + uuid.uuid4().hex
    info.update(CFBundleIdentifier=domain, CFBundleExecutable=binary.name, LSUIElement=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    (contents / "Resources").symlink_to(LIBRARY.parents[1] / "Resources")
    arguments = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                 "-target", f"{platform.machine()}-apple-macos15.6", "-module-cache-path", str(temporary / "ModuleCache"),
                 "-I", str(PRODUCTS), "-I", str(PRODUCTS / "include"), "-F", str(PRODUCTS)]
    for modulemap in (BUILD / "Build/Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
                  "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(LIBRARY),
                  "-Xlinker", "-rpath", "-Xlinker", str(PRODUCTS),
                  "-Xlinker", "-rpath", "-Xlinker", str(LIBRARY.parent),
                  str(ROOT / "mac/tests/BrowserWebExtensionTests.swift"), "-o", str(binary)]
    subprocess.run(arguments, check=True, cwd=ROOT)

    fixture = temporary / "fixture"
    extension = fixture / "extension"
    extension.mkdir(parents=True)
    manifest = {"manifest_version": 3, "name": "Fixture Extension", "description": "Disposable browser extension fixture", "version": "1.0",
                "permissions": ["storage"], "host_permissions": ["http://127.0.0.1/*"],
                "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"]}],
                "background": {"service_worker": "background.js"},
                "action": {"default_title": "Open fixture", "default_popup": "popup.html"},
                "options_ui": {"page": "options.html"}}
    (extension / "manifest.json").write_text(json.dumps(manifest))
    (extension / "content.js").write_text("browser.runtime.sendMessage({visit:true}).then(value => { document.body.dataset.extensionVisits = String(value); });")
    (extension / "background.js").write_text("""browser.runtime.onMessage.addListener(async message => {
      if (message.network) {
        await browser.storage.local.set({networkMarker:true});
        try { return await (await fetch(message.network, {signal:AbortSignal.timeout(2000)})).text(); }
        catch { return 'blocked'; }
      }
      if (!message.visit) return null;
      const old = await browser.storage.local.get('visits');
      const visits = (old.visits || 0) + 1;
      await browser.storage.local.set({visits});
      return visits;
    });""")
    (extension / "popup.html").write_text('<!doctype html><body><p id="popup">Extension popup</p></body>')
    (extension / "options.html").write_text('<!doctype html><body><p>Extension options</p></body>')
    active = fixture / "active-tab"
    active.mkdir()
    (active / "manifest.json").write_text(json.dumps({"manifest_version": 3, "name": "Active Tab Fixture", "description": "Disposable action fixture", "version": "1.0",
       "permissions": ["activeTab", "scripting"], "background": {"service_worker": "background.js"},
       "action": {"default_title": "Run current page"}}))
    (active / "background.js").write_text("""browser.action.onClicked.addListener(async tab => {
      await browser.scripting.executeScript({target:{tabId:tab.id},func:() => {document.body.dataset.extensionAction = 'done';}});
    });""")
    with zipfile.ZipFile(fixture / "extension.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        for file in extension.iterdir():
            archive.write(file, file.name)
    malformed = fixture / "malformed"
    malformed.mkdir()
    (malformed / "manifest.json").write_text("{}")
    linked = fixture / "linked"
    linked.mkdir()
    (linked / "manifest.json").write_text(json.dumps(manifest))
    (linked / "outside").symlink_to(extension / "background.js")
    with zipfile.ZipFile(fixture / "oversize.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        archive.writestr("large", bytes(65 * 1024 * 1024))
    many = fixture / "many"
    many.mkdir()
    (many / "manifest.json").write_text(json.dumps(manifest))
    for index in range(4096):
        (many / str(index)).touch()
    wrong_header = bytearray((fixture / "extension.zip").read_bytes())
    wrong_header[30] = ord('x')
    (fixture / "mismatch.zip").write_bytes(wrong_header)
    with zipfile.ZipFile(fixture / "traversal.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        archive.writestr("../outside", "unsafe")
    with zipfile.ZipFile(fixture / "linked.zip", "w") as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        link = zipfile.ZipInfo("link")
        link.create_system = 3
        link.external_attr = 0o120777 << 16
        archive.writestr(link, "../outside")
    home = temporary / "home"
    (home / ".config/zshell-dev").mkdir(parents=True)
    (home / ".config/zshell-dev/config.toml").write_text("ai.enabled = false\nbrowser.content-blocking = false\n")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(temporary) + "/")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        subprocess.run([str(binary), base, str(fixture)], cwd=ROOT, env=environment, check=True, timeout=100)
        assert not any("remote-background" in path or "remote-popup" in path for path in Page.requests), Page.requests
        subprocess.run([str(binary), base, str(fixture), "persistence"], cwd=ROOT, env=environment, check=True, timeout=20)
    finally:
        server.shutdown()
        server.server_close()
        subprocess.run(["defaults", "delete", domain], env=environment, capture_output=True)

print("WebExtension test binaries, browser stores, extensions, servers, homes and caches removed")
