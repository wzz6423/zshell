"""Exercise the production image loader with controlled, real HTTP completions.

python3 -B mac/tests/test_markdown_image_loader.py
python3 -B mac/tests/test_markdown_image_loader.py --source-ref <pre-fix-ref> --case large-unknown
python3 -B mac/tests/test_markdown_image_loader.py --source-ref <pre-fix-ref> --case local-fifo
python3 -B mac/tests/test_markdown_image_loader.py --source-ref <pre-fix-ref> --case local-oversized
python3 -B mac/tests/test_markdown_image_loader.py --built-app '/path/to/zshell Debug.app'
python3 -B mac/tests/test_markdown_image_loader.py --sample-rss

No production test hook or app build is needed for the source probe. The HTTP
server, source copy, module cache, disposable home and binary are cleaned up.
Older source revisions receive task-handle bookkeeping only, without the
generation check, so the same awaited regression still demonstrates the bug.
"""

import argparse
import gzip
import http.server
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib

sys.dont_write_bytecode = True
from test_file_tree_background import ROOT, built_app_arguments, compiler_arguments


LIMIT = 20 << 20
OVERSIZED = 64 << 20
SCENARIOS = ("cache", "late-success", "early-success", "late-failure", "reset-storm", "oversized", "streamed",
             "large-known", "large-unknown", "large-chunked", "large-compressed",
             "limit-known", "limit-unknown", "limit-chunked", "limit-compressed",
             "concurrent", "large-reset", "cancellation", "stall",
             "local-image", "local-fifo", "local-oversized")


def png(width, padding=0):
    def chunk(kind, data):
        return (struct.pack("!I", len(data)) + kind + data
                + struct.pack("!I", zlib.crc32(kind + data)))
    header = struct.pack("!IIBBBBB", width, 1, 8, 6, 0, 0, 0)
    row = b"\0" + b"\xff\0\0\xff" * width
    metadata = chunk(b"tEXt", b"fixture\0" + b"x" * padding) if padding else b""
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(row)) + metadata + chunk(b"IEND", b""))


def sized_png(width, size):
    """Keep decoded pixels tiny while the valid PNG reaches an exact byte boundary."""
    return png(width, padding=size - len(png(width, padding=1)) + 1)


def observable_source(source):
    """Expose old loads' real tasks without adding the generation fix under test."""
    if "private(set) var inFlight: [URL: Task<Void, Never>] = [:]" in source:
        return source
    replacements = {
        "private var inFlight: Set<URL> = []": "private(set) var inFlight: [URL: Task<Void, Never>] = [:]",
        "!inFlight.contains(url)": "inFlight[url] == nil",
        "inFlight.insert(url)\n        Task {": "inFlight[url] = Task {",
        "self.inFlight.remove(url)": "self.inFlight.removeValue(forKey: url)",
    }
    for before, after in replacements.items():
        if source.count(before) != 1:
            raise SystemExit("Expected exactly one earlier task-bookkeeping boundary")
        source = source.replace(before, after)
    return source


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.lock = threading.Lock()
        self.requests = {}
        self.gates = {}
        self.records = {}
        self.images = {}
        self.stopping = threading.Event()

    def image(self, width, size, compressed=False):
        with self.lock:
            key = (width, size, compressed)
            if key not in self.images:
                data = sized_png(width, size)
                self.images[key] = gzip.compress(data) if compressed else data
            return self.images[key]

    def release_all(self):
        with self.lock:
            for gate in self.gates.values():
                gate.set()


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if len(parts) == 2 and parts[0] == "image":
            scenario = parts[1].removesuffix(".png")
            with self.server.lock:
                number = self.server.requests.get(scenario, 0) + 1
                self.server.requests[scenario] = number
                gate = self.server.gates[(scenario, number)] = threading.Event()
                self.record_key = (scenario, number)
                self.server.records[self.record_key] = {
                    "sent": 0, "total": 0, "complete": False, "disconnected": False,
                }
            if not gate.wait(10):
                self.respond(504, b"unreleased fixture request", "text/plain")
            elif (scenario == "late-failure" and number == 1
                  or scenario == "reset-storm" and number % 3 == 2):
                self.respond(503, b"old document image failed", "text/plain")
            elif scenario == "oversized" and number == 1:
                image = png(1)
                self.respond(200, image + bytes((20 << 20) + 1 - len(image)), "image/png")
            elif scenario == "streamed":
                self.respond(200, png(number, padding=64 << 10), "image/png", include_length=False)
            elif scenario.startswith(("large-", "limit-", "concurrent-")) or scenario == "stall":
                self.stream(scenario, number)
            elif scenario == "cancellation" and number == 1:
                self.stream("limit-chunked", number)
            else:
                self.respond(200, png(number), "image/png")
        elif len(parts) == 2 and parts[0] == "state":
            with self.server.lock:
                count = self.server.requests.get(parts[1], 0)
                records = [self.server.records[(parts[1], number)] for number in range(1, count + 1)]
                state = json.dumps({"requests": count, "records": records}).encode()
            self.respond(200, state, "application/json")
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
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        self.record(total=len(body))
        try:
            self.wfile.write(body)
            self.wfile.flush()
            self.record(sent=len(body), complete=True)
        except (BrokenPipeError, ConnectionResetError):
            self.record(disconnected=True)

    def stream(self, scenario, number):
        oversized = scenario.startswith("limit-")
        compressed = scenario.endswith("compressed")
        chunked = scenario.endswith("chunked") or scenario == "large-reset" or scenario.startswith("concurrent-")
        data = self.server.image(number, OVERSIZED if oversized else LIMIT, compressed)
        self.record(total=len(data))
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.close_connection = True
        if compressed:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(data)))
        elif chunked:
            self.send_header("Transfer-Encoding", "chunked")
        elif scenario.endswith("known") and not scenario.endswith("unknown"):
            self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        sent = 0
        chunk_size = 4 << 10 if compressed else 64 << 10
        delay = 0.03 if compressed else 0.002
        try:
            while sent < len(data) and not self.server.stopping.is_set():
                chunk = data[sent:sent + chunk_size]
                if chunked:
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                else:
                    self.wfile.write(chunk)
                self.wfile.flush()
                sent += len(chunk)
                self.record(sent=sent)
                if scenario == "stall" and sent == chunk_size:
                    self.server.stopping.wait(17)
                else:
                    self.server.stopping.wait(delay)
            if sent == len(data):
                if chunked:
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                self.record(complete=True)
        except (BrokenPipeError, ConnectionResetError):
            self.record(disconnected=True)

    def record(self, **updates):
        key = getattr(self, "record_key", None)
        if key is not None:
            with self.server.lock:
                self.server.records[key].update(updates)

    def log_message(self, *_):
        pass


def main():
    """Compile once, then give each HTTP completion scenario an isolated loader process."""
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--source-ref", help="Run the regression against an earlier production revision")
    source.add_argument("--built-app", type=Path, help="Use an existing Debug app without rebuilding it")
    parser.add_argument("--case", choices=SCENARIOS, action="append", help="Run only the selected scenario(s)")
    parser.add_argument("--sample-rss", action="store_true", help="Observe the loader process's RSS without a memory threshold")
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
                earlier_source = subprocess.check_output(
                    ["git", "show", f"{options.source_ref}:{path}"], cwd=ROOT, text=True)
                production.write_text(observable_source(earlier_source))
                if "BoundedHTTPData.data(" in earlier_source:
                    helper = temporary / "BoundedHTTPData.swift"
                    helper.write_text(subprocess.check_output(
                        ["git", "show", f"{options.source_ref}:mac/zshell/BoundedHTTPData.swift"], cwd=ROOT, text=True))
                    command += [str(helper)]
            else:
                production = ROOT / path
                helper = ROOT / "mac/zshell/BoundedHTTPData.swift"
                if helper.exists():
                    command += [str(helper)]
            command += [str(production)]
        binary = temporary / "markdown-image-tests"
        command += [str(ROOT / "mac/tests/MarkdownImageLoaderTests.swift"), "-o", str(binary)]
        subprocess.run(command, cwd=ROOT, check=True, timeout=120)
        home = temporary / "home"
        home.mkdir()
        local_root = temporary / "local"
        local_root.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home))
        server = FixtureServer()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            scenarios = options.case or SCENARIOS
            for scenario in scenarios:
                started = time.monotonic()
                process = subprocess.Popen(
                    [str(binary), f"http://127.0.0.1:{server.server_port}", scenario, str(local_root)],
                    cwd=ROOT, env=environment)
                samples = []
                stop_sampling = threading.Event()
                sampler = None
                if options.sample_rss:
                    sampler = threading.Thread(target=sample_rss, args=(process, stop_sampling, samples), daemon=True)
                    sampler.start()
                try:
                    returncode = process.wait(timeout=scenario_timeout(scenario))
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    returncode = 1
                    print(f"FAIL {scenario}: the actual loader task exceeded the subprocess deadline")
                finally:
                    stop_sampling.set()
                    if sampler:
                        sampler.join()
                elapsed = time.monotonic() - started
                memory = f", observed peak RSS {max(samples) / 1024:.1f} MiB" if samples else ""
                print(f"Scenario {scenario}: {elapsed:.3f}s{memory}", flush=True)
                if returncode:
                    failures.append(scenario)
            print(f"Markdown image loader scenarios: {len(scenarios) - len(failures)} passed, {len(failures)} failed")
        finally:
            server.stopping.set()
            server.release_all()
            server.shutdown()
            server.server_close()
            thread.join()
    return 1 if failures else 0


def scenario_timeout(scenario):
    """A FIFO used to block inside the detached read, so that case fails closed."""
    if scenario == "local-fifo":
        return 8
    return 45


def sample_rss(process, stop, samples):
    """Observe only the loader process; fixture and compiler allocations are separate."""
    while process.poll() is None and not stop.is_set():
        result = subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(process.pid)],
                                capture_output=True, text=True, timeout=2)
        if result.returncode == 0 and result.stdout.strip().isdigit():
            samples.append(int(result.stdout))
        stop.wait(0.1)


if __name__ == "__main__":
    raise SystemExit(main())
