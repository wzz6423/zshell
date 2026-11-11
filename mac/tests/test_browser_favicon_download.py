"""Exercise production favicon downloads against disposable local HTTP fixtures.

Use --built-app '/path/to/zshell Debug.app' to link the same regressions against
the compiled app module; the default source probe needs no app build.
"""

import argparse
import gzip
import http.server
import os
from pathlib import Path
import subprocess
import ssl
import tempfile
import threading
import time
import sys

sys.dont_write_bytecode = True
from test_file_tree_background import built_app_arguments


ROOT = Path(__file__).resolve().parents[2]
LIMIT = 2 * 1024 * 1024
OVERSIZED = 8 * LIMIT
CHUNK = b"x" * 65536
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--built-app", type=Path)
options = parser.parse_args()


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.lstrip("/")
        if path.startswith("cancel-status-"):
            target = path.replace("cancel-status-", "cancel-")
            with self.server.records_lock:
                body = b"started" if target in self.server.started else b"waiting"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        with self.server.records_lock:
            self.server.started.add(path)
        if path == "authenticate" and self.headers.get("Authorization") != "Basic Zml4dHVyZTpmaXh0dXJl":
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Favicon fixture"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.record(path, 0)
            return
        if path.startswith("redirect-"):
            target = {"redirect-large": "known", "redirect-small": "small",
                      "redirect-policy": "policy-unsafe", "redirect-late": "late-target"}[path]
            self.send_response(302)
            self.send_header("Location", "/" + target)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.record(path, 0)
            return
        if path in {"small", "recovery", "policy-target", "authenticate"}:
            self.send_response(200)
            self.send_header("Content-Length", "8")
            self.end_headers()
            self.wfile.write(b"icondata")
            self.record(path, 8)
            return
        self.send_response(500 if path == "rejected" else 200)
        chunked = path == "chunked"
        compressed = path == "compressed"
        size = LIMIT if path == "exact" else OVERSIZED
        payload = gzip.compress(b"x" * size) if compressed else None
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        elif payload is not None:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(payload)))
        elif path in {"known", "rejected", "exact", "policy-unsafe"}:
            self.send_header("Content-Length", str(size))
        self.send_header("Content-Type", "image/png")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        sent = 0
        delay = 0.015 if path.startswith("cancel") else 0.003
        try:
            if payload is not None:
                self.wfile.write(payload)
                self.wfile.flush()
                sent = len(payload)
            else:
                while sent < size:
                    if chunked:
                        self.wfile.write(f"{len(CHUNK):x}\r\n".encode() + CHUNK + b"\r\n")
                    else:
                        self.wfile.write(CHUNK)
                    self.wfile.flush()
                    sent += len(CHUNK)
                    time.sleep(delay)
                if chunked:
                    self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.record(path, sent)

    def record(self, path, sent):
        with self.server.records_lock:
            self.server.records.setdefault(path, []).append(sent)

    def log_message(self, *_):
        pass


def production_fixture():
    source = (ROOT / "mac/zshell/BrowserView.swift").read_text()
    start = source.index("    private static func faviconData(from url: URL, routing: BrowserRemoteRouting?) async -> Data? {")
    end = source.index("    /// Decode remote artwork", start)
    constant = next(line for line in source.splitlines() if "private static let maximumFaviconBytes =" in line)
    return """import Foundation

@MainActor final class BrowserRemoteRouting {
    func faviconData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

@MainActor enum BrowserFaviconProduction {
""" + constant + "\n" + source[start:end] + """
    static func download(_ url: URL) async -> Data? { await faviconData(from: url, routing: nil) }
}
"""


with tempfile.TemporaryDirectory(prefix="zshell-favicon-download-") as temporary:
    directory = Path(temporary)
    fixture = directory / "ProductionFavicon.swift"
    fixture.write_text(production_fixture())
    binary = directory / "favicon-tests"
    sources = [str(fixture), str(ROOT / "mac/tests/BrowserFaviconDownloadTests.swift")]
    helper = ROOT / "mac/zshell/BrowserFaviconDownload.swift"
    if options.built_app:
        fixture.write_text("@testable import zshell\n" + fixture.read_text())
        sources += built_app_arguments(options.built_app.resolve())
        sources += ["-D", "BOUNDED_FAVICON_TESTS", "-D", "ZSHELL_FAVICON_BUILT_APP"]
    elif helper.exists():
        sources += ["-D", "BOUNDED_FAVICON_TESTS", str(helper)]
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(directory / "modules"), *sources, "-o", str(binary),
    ], check=True, cwd=ROOT)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    server.records = {}
    server.started = set()
    server.records_lock = threading.Lock()
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    certificate = directory / "certificate.pem"
    key = directory / "key.pem"
    subprocess.run([
        "/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-subj", "/CN=Favicon fixture", "-keyout", str(key), "-out", str(certificate),
    ], check=True, capture_output=True)
    secure_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    secure_server.socket = context.wrap_socket(secure_server.socket, server_side=True)
    secure_server.records = {}
    secure_server.started = set()
    secure_server.records_lock = threading.Lock()
    secure_worker = threading.Thread(target=secure_server.serve_forever, daemon=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    environment["HOME"] = str(directory / "home")
    environment["CFFIXED_USER_HOME"] = environment["HOME"]
    Path(environment["HOME"]).mkdir()
    worker.start()
    secure_worker.start()
    try:
        subprocess.run([str(binary), f"http://127.0.0.1:{server.server_port}/",
                        f"https://127.0.0.1:{secure_server.server_port}/"], check=True,
                       env=environment, timeout=35)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            with server.records_lock:
                if "recovery" in server.records and all(f"cancel-{i}" in server.records for i in range(12)):
                    break
            time.sleep(0.02)
        with server.records_lock:
            records = dict(server.records)
        for path in ("known", "rejected"):
            assert max(records[path]) < LIMIT // 2, (path, records[path])
        for path in ("unknown", "chunked", *(f"concurrent-{i}" for i in range(8))):
            assert max(records[path]) <= LIMIT + 8 * len(CHUNK), (path, records[path])
        assert records["exact"] == [LIMIT], records["exact"]
        for index in range(12):
            sent = records[f"cancel-{index}"]
            assert max(sent) < LIMIT // 2, sent
        assert "policy-unsafe" not in records, records.get("policy-unsafe")
        assert "late-target" not in records, records.get("late-target")
        assert not secure_server.records, secure_server.records
        if helper.exists():
            remote = (ROOT / "mac/zshell/BrowserRemoteRouting.swift").read_text()
            assert "BrowserFaviconDownload.data(for: request, session: faviconSession, delegate: FaviconRedirects())" in remote
        print("Server transfer counts:", {path: max(values) for path, values in sorted(records.items())})
        print("Favicon HTTP transfers stop at the response limit or cancellation; temporary resources cleaned")
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)
        secure_server.shutdown()
        secure_server.server_close()
        secure_worker.join(timeout=2)
