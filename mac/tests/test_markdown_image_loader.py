"""Exercise the production image loader with controlled, real HTTP completions.

python3 -B mac/tests/test_markdown_image_loader.py
python3 -B mac/tests/test_markdown_image_loader.py --source-ref <pre-fix-ref>
python3 -B mac/tests/test_markdown_image_loader.py --built-app '/path/to/zshell Debug.app'

No production test hook or app build is needed for the source probe. The HTTP
server, source copy, module cache, disposable home and binary are cleaned up.
"""

import argparse
import http.server
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import zlib

sys.dont_write_bytecode = True
from test_file_tree_background import ROOT, built_app_arguments, compiler_arguments


def png(width):
    def chunk(kind, data):
        return (struct.pack("!I", len(data)) + kind + data
                + struct.pack("!I", zlib.crc32(kind + data)))
    header = struct.pack("!IIBBBBB", width, 1, 8, 6, 0, 0, 0)
    row = b"\0" + b"\xff\0\0\xff" * width
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(row)) + chunk(b"IEND", b""))


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.lock = threading.Lock()
        self.requests = {}
        self.gates = {}

    def release_all(self):
        with self.lock:
            for gate in self.gates.values():
                gate.set()


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if len(parts) == 2 and parts[0] == "image":
            scenario = parts[1].removesuffix(".png")
            with self.server.lock:
                number = self.server.requests.get(scenario, 0) + 1
                self.server.requests[scenario] = number
                gate = self.server.gates[(scenario, number)] = threading.Event()
            if not gate.wait(10):
                self.respond(504, b"unreleased fixture request", "text/plain")
            elif (scenario == "late-failure" and number == 1
                  or scenario == "reset-storm" and number % 3 == 2):
                self.respond(503, b"old document image failed", "text/plain")
            elif scenario in ("oversized", "streamed-oversized") and number == 1:
                image = png(1)
                self.respond(200, image + bytes((20 << 20) + 1 - len(image)), "image/png",
                             include_length=scenario != "streamed-oversized")
            else:
                self.respond(200, png(number), "image/png")
        elif len(parts) == 2 and parts[0] == "state":
            with self.server.lock:
                count = self.server.requests.get(parts[1], 0)
            self.respond(200, json.dumps({"requests": count}).encode(), "application/json")
        elif len(parts) == 3 and parts[0] == "release":
            with self.server.lock:
                gate = self.server.gates.get((parts[1], int(parts[2])))
            if gate is None:
                self.respond(404, b"unknown request", "text/plain")
            else:
                gate.set()
                self.respond(200, b"released", "text/plain")
        else:
            self.respond(404, b"unknown fixture path", "text/plain")

    def respond(self, status, body, content_type, include_length=True):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        if include_length:
            self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def main():
    """Compile once, then give each HTTP completion scenario an isolated loader process."""
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--source-ref", help="Run the regression against an earlier production revision")
    source.add_argument("--built-app", type=Path, help="Use an existing Debug app without rebuilding it")
    options = parser.parse_args()
    failures = []
    with tempfile.TemporaryDirectory(prefix="zshell-markdown-images-") as directory:
        temporary = Path(directory)
        command = compiler_arguments(temporary)
        if options.built_app:
            command += ["-D", "ZSHELL_MARKDOWN_IMAGE_BUILT_APP"]
            command += built_app_arguments(options.built_app.resolve())
        else:
            path = "mac/zshell/MarkdownImageLoader.swift"
            if options.source_ref:
                production = temporary / "MarkdownImageLoader.swift"
                production.write_bytes(subprocess.check_output(
                    ["git", "show", f"{options.source_ref}:{path}"], cwd=ROOT))
            else:
                production = ROOT / path
            command += [str(production)]
        binary = temporary / "markdown-image-tests"
        command += [str(ROOT / "mac/tests/MarkdownImageLoaderTests.swift"), "-o", str(binary)]
        subprocess.run(command, cwd=ROOT, check=True, timeout=120)
        home = temporary / "home"
        home.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home))
        server = FixtureServer()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            scenarios = ("cache", "late-success", "early-success", "late-failure", "reset-storm",
                         "oversized", "streamed-oversized")
            for scenario in scenarios:
                result = subprocess.run([str(binary), f"http://127.0.0.1:{server.server_port}", scenario],
                                        cwd=ROOT, env=environment, timeout=45)
                if result.returncode:
                    failures.append(scenario)
            print(f"Markdown image loader scenarios: {len(scenarios) - len(failures)} passed, {len(failures)} failed")
        finally:
            server.release_all()
            server.shutdown()
            server.server_close()
            thread.join()
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
