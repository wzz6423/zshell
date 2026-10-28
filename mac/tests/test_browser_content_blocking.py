"""Exercise production BrowserTab, native settings, and real WebKit HTTP requests.

Build Debug first, then run with ZSHELL_TEST_DERIVED_DATA=/tmp/zshell-build.
Optional ZSHELL_TEST_FILTER_LISTS names two local downloaded default-list files.
The fixture uses a temporary HOME and never touches the user's browser data.
"""

import base64
import http.server
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug"))
PRODUCTS = BUILD / "Build/Products/Debug"
LIBRARY = PRODUCTS / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jG3sAAAAASUVORK5CYII=")
PAGE = b'''<!doctype html><style>div { display:block }</style>
<div class="hidden-ad">Hidden</div><div class="except-ad">Exception</div>
<div class="scoped-ad">Scoped</div><div class="negative-ad">Negative</div>
<script>
window.fixtureResults = {};
Promise.all(['blocked.png','allowed.png','normal.png','scoped.png','negative.png','mixed.png'].map(name => new Promise(resolve => {
 const image = new Image(); image.onload = () => { fixtureResults[name] = true; resolve(); };
 image.onerror = () => { fixtureResults[name] = false; resolve(); };
 image.src = '/' + name + location.search;
 document.body.append(image);
}))).then(() => window.fixtureDone = true);
</script>'''
FILTERS = b'''[Adblock Plus 2.0]
/blocked.png$image
/allowed.png$image
@@/allowed.png$image
/scoped.png$image,domain=localhost
/negative.png$image,domain=~127.0.0.1
/mixed.png$image,domain=127.0.0.1|~sub.127.0.0.1
##.hidden-ad
##.except-ad
127.0.0.1#@#.except-ad
localhost##.scoped-ad
~127.0.0.1##.negative-ad
||unsupported.example^$redirect=noopjs
'''


class Fixture(http.server.BaseHTTPRequestHandler):
    hits = []
    fail_updates = False

    def do_GET(self):
        self.hits.append(self.path)
        path = urlparse(self.path).path
        if path == "/fail-updates":
            Fixture.fail_updates = True
            self.send_response(200)
            self.end_headers()
            return
        if path == "/slow.txt":
            time.sleep(0.6)
            body, kind = b"/allowed.png$image", "text/plain"
        elif path == "/oversize.txt":
            self.send_response(200)
            self.send_header("Content-Length", str(9 * 1024 * 1024))
            self.end_headers()
            return
        elif path == "/missing.txt" or (path == "/filters.txt" and self.fail_updates):
            self.send_error(503)
            return
        elif path == "/filters.txt":
            body = b"[Adblock Plus 2.0]\n/normal.png$image" if "version=2" in self.path else FILTERS
            kind = "text/plain"
        elif path.endswith(".png"):
            body, kind = PNG, "image/png"
        else:
            body, kind = PAGE, "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix="zshell-content-test-") as temporary:
    temporary = Path(temporary)
    binary = temporary / "content-tests"
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(PRODUCTS), "-I", str(PRODUCTS / "include"), "-F", str(PRODUCTS),
    ]
    for modulemap in (BUILD / "Build/Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in (
        "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
    ):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += [
        "-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(LIBRARY),
        "-Xlinker", "-rpath", "-Xlinker", str(PRODUCTS),
        "-Xlinker", "-rpath", "-Xlinker", str(LIBRARY.parent),
        str(ROOT / "mac/tests/BrowserContentBlockingTests.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, check=True, cwd=ROOT)
    home = temporary / "home"
    home.mkdir()
    environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
    for key in ("ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN"):
        environment.pop(key, None)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        extra = os.environ.get("ZSHELL_TEST_FILTER_LISTS", "").split(os.pathsep)
        extra = [value for value in extra if value]
        subprocess.run([str(binary), base, "verify", *extra], env=environment, check=True, timeout=190)
        subprocess.run([str(binary), base, "persistence"], env=environment, check=True, timeout=20)
        enabled = [url for url in Fixture.hits if "case=enabled" in url]
        assert not any(url.startswith("/blocked.png?") for url in enabled), enabled
        assert any(url.startswith("/allowed.png?") for url in enabled), enabled
        assert any(url.startswith("/blocked.png?") and "case=disabled" in url for url in Fixture.hits), Fixture.hits
        assert not any(url.startswith("/normal.png?") and "case=updated" in url for url in Fixture.hits), Fixture.hits
        print("HTTP server evidence: blocked requests absent, exceptions/disabled requests present; updated list effective")
        print(json.dumps({"requests": len(Fixture.hits), "enabled_requests": enabled}, ensure_ascii=False))
    finally:
        server.shutdown()
        server.server_close()
