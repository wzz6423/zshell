"""Verify remote browser routing with a private, real OpenSSH and HTTP/WS fixture.

The default transport probe needs no app build or GUI. Pass --derived-data for
the production BrowserTab/AppKit/terminal probe built in that DerivedData.
All servers, identities, homes and binaries are private
temporary resources and are removed after the probe.
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import pwd
import re
import socket
import struct
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[2]


def run(*arguments, **kwargs):
    return subprocess.run(arguments, cwd=ROOT, check=True, **kwargs)


def unused_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


class Fixture:
    def __init__(self, directory):
        self.directory = directory
        self.processes = []
        self.servers = []
        self.threads = []
        self.requests = []
        self.ssh_log = directory / "sshd.log"
        self.config = directory / "ssh_config"

    def __enter__(self):
        self.directory.chmod(0o700)
        key = self.directory / "identity"
        host_key = self.directory / "host_key"
        for target in (key, host_key):
            run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(target))
        port = unused_port()
        known_hosts = self.directory / "known_hosts"
        public = host_key.with_suffix(".pub").read_text().split()
        known_hosts.write_text(f"[127.0.0.1]:{port} {public[0]} {public[1]}\n")
        authorized = self.directory / "authorized_keys"
        authorized.write_bytes(key.with_suffix(".pub").read_bytes())
        authorized.chmod(0o600)
        user = pwd.getpwuid(os.getuid()).pw_name
        self.address = f"ssh://{user}@127.0.0.1:{port}"
        self.host = "127.0.0.1"
        self.ssh_port = port
        server_config = self.directory / "sshd_config"
        server_config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {host_key}
PidFile {self.directory / 'sshd.pid'}
AuthorizedKeysFile {authorized}
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
AllowUsers {user}
AllowTcpForwarding local
PermitOpen any
LogLevel DEBUG3
""")
        self.config.write_text(f"""Host *
  User {user}
  IdentityFile {key}
  IdentitiesOnly yes
  UserKnownHostsFile {known_hosts}
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  BatchMode yes
  ConnectTimeout 3
""")
        log = self.ssh_log.open("wb")
        server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(server_config)],
                                  cwd=ROOT, stdout=log, stderr=log)
        log.close()
        self.processes.append(server)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if server.poll() is not None:
                raise RuntimeError(self.ssh_log.read_text())
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.05)
        run("/usr/bin/ssh", "-F", str(self.config), "-p", str(port), self.host, "true",
            capture_output=True, timeout=5)
        self.primary = self.http_server("primary")
        self.secondary = self.http_server("secondary")
        # One port served separately on 127.0.0.1 and ::1 shows which loopback
        # address a routed URL really reached.
        while True:
            self.loopback4 = self.http_server("loopback4")
            try:
                self.loopback6 = self.http_server("loopback6", ("::1", self.loopback4.server_port))
                break
            except OSError:
                pass
        return self

    def __exit__(self, *_):
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(timeout=2)
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)

    def http_server(self, label, address=("127.0.0.1", 0)):
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                fixture.requests.append((label, self.path, self.headers.get("Host"), self.headers.get("Cookie")))
                if self.path.startswith("/socket"):
                    self.websocket()
                    # Unread close-frame bytes must not be parsed as a request.
                    self.close_connection = True
                    return
                if self.path == "/favicon-redirect":
                    self.send_response(302)
                    self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/favicon-target.png?via={self.headers.get('Host')}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.path.startswith("/redirect"):
                    self.send_response(302)
                    self.send_header("Location", f"http://localhost:{fixture.secondary.server_port}/page/next?from=redirect&encoded=%2F#fragment")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.path.startswith("/script.js"):
                    body = b"window.fixtureScript='loaded';"
                    content_type = "text/javascript"
                elif self.path.startswith("/dynamic.js"):
                    body = b"window.fixtureDynamic='loaded';"
                    content_type = "text/javascript"
                elif self.path.startswith("/api"):
                    body = json.dumps({"server": label, "path": self.path, "host": self.headers.get("Host")}).encode()
                    content_type = "application/json"
                elif self.path.startswith("/pixel") or self.path == "/favicon.ico" or self.path.startswith("/favicon-target.png"):
                    body = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afoQAAAAASUVORK5CYII=")
                    content_type = "image/png"
                elif self.path.startswith("/page"):
                    other = fixture.primary.server_port if label == "secondary" else fixture.secondary.server_port
                    body = f"""<!doctype html><html><head><title>{label} remote preview</title>
<link rel="icon" href="/favicon-redirect"><script src="http://localhost:{other}/script.js"></script>
<style>body{{background:#16324f;color:white;font:18px system-ui;padding:24px}} img{{width:32px;height:32px}}</style></head>
<body><h1>{label} remote preview</h1><a id="next" href="/page/navigation?value=%2F#link">Next page</a>
<input id="field" aria-label="Test value"><img id="pixel" src="http://127.0.0.1:{other}/pixel.png">
<iframe id="child" src="http://localhost:{other}/frame"></iframe><div id="result">loading</div>
<script>
window.fixtureState={{path:location.pathname,query:location.search,hash:location.hash,origin:location.origin}};
fetch('http://localhost:{other}/api?cross=port').then(r=>r.json()).then(v=>window.fixtureState.api=v);
const ws=new WebSocket('ws://localhost:{other}/socket?hmr=1');
ws.onopen=()=>ws.send('hmr-echo');ws.onmessage=e=>{{window.fixtureState.websocket=e.data;document.querySelector('#result').textContent=e.data}};
window.fixtureState.cookie=document.cookie;
const dynamic=document.createElement('script');dynamic.src='http://localhost:{other}/dynamic.js';document.head.appendChild(dynamic);
</script></body></html>""".encode()
                    content_type = "text/html"
                elif self.path == "/frame":
                    body = b"<!doctype html><p>remote child frame</p>"
                    content_type = "text/html"
                else:
                    body = json.dumps({"server": label, "path": self.path, "host": self.headers.get("Host")}).encode()
                    content_type = "application/json"
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def websocket(self):
                key = self.headers.get("Sec-WebSocket-Key", "")
                accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                self.end_headers()
                self.connection.settimeout(10)
                try:
                    while True:
                        header = self.rfile.read(2)
                        if len(header) != 2 or header[0] & 15 == 8:
                            return
                        count = header[1] & 127
                        if count == 126:
                            count = struct.unpack("!H", self.rfile.read(2))[0]
                        if count > 4096:
                            return
                        mask = self.rfile.read(4) if header[1] & 128 else None
                        data = self.rfile.read(count)
                        if mask:
                            data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
                        if len(data) < 126:
                            self.wfile.write(bytes([0x81, len(data)]) + data)
                            self.wfile.flush()
                except (OSError, ValueError):
                    return

            def log_message(self, *_):
                pass

        class Server(http.server.ThreadingHTTPServer):
            address_family = socket.AF_INET6 if ":" in address[0] else socket.AF_INET

        server = Server(address, Handler)
        server.daemon_threads = True
        self.servers.append(server)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        self.threads.append(thread)
        thread.start()
        return server


TRANSPORT_PROBE = r'''
import Foundation

@main struct TransportProbe {
    static func main() {
        do { try run() }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }

    static func run() throws {
        let endpoint = try SSHEndpoint(host: "127.0.0.1", port: Int(CommandLine.arguments[1]))
        let transport = OpenSSHTransport(timeout: 3)
        for iteration in 0..<2 {
            let tunnel = try transport.startDynamicForwarding(endpoint: endpoint)
            print("READY \(iteration) \(tunnel.port) \(tunnel.processID)")
            fflush(stdout)
            _ = readLine()
            tunnel.close()
            let deadline = Date().addingTimeInterval(3)
            while tunnel.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            precondition(!tunnel.isRunning)
            print("CLOSED \(iteration)")
            fflush(stdout)
        }
    }
}
'''


def verify_transport(directory, fixture):
    host = directory / "RemoteHost.swift"
    host.write_text((ROOT / "mac/zshell/RemoteHost.swift").read_text().split("nonisolated struct RemoteSessionInfo:")[0])
    source = directory / "TransportProbe.swift"
    source.write_text(TRANSPORT_PROBE)
    binary = directory / "transport-probe"
    run("xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(directory / "ModuleCache"), str(ROOT / "mac/zshell/RemoteSSH.swift"),
        str(ROOT / "mac/zshell/SSHAgentEnvironment.swift"), str(host), str(source), "-o", str(binary))
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    environment.update({"ZSHELL_SSH_CONFIG_FILE": str(fixture.config), "CFFIXED_USER_HOME": str(directory),
                        "ZSHELL_SSH_AGENT_RESOLVED": "1"})
    process = subprocess.Popen([str(binary), str(fixture.ssh_port)], cwd=ROOT, env=environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    fixture.processes.append(process)
    for iteration in range(2):
        ready = process.stdout.readline().split()
        if len(ready) != 4 or ready[0] != "READY":
            raise RuntimeError(process.stderr.read())
        proxy = ready[2]
        for name, server in (("localhost", fixture.primary), ("127.0.0.1", fixture.secondary)):
            target = f"http://{name}:{server.server_port}/route/path?value=%2F&next=a%20b"
            response = run("/usr/bin/curl", "--silent", "--show-error", "--noproxy", "",
                           "--socks5-hostname", f"127.0.0.1:{proxy}", "--max-time", "5", target,
                           capture_output=True, text=True)
            result = json.loads(response.stdout)
            assert result["path"] == "/route/path?value=%2F&next=a%20b", result
            assert result["host"] == f"{name}:{server.server_port}", result
        sockets = run("/usr/sbin/lsof", "-nP", "-a", "-p", ready[3], "-iTCP", "-sTCP:LISTEN", capture_output=True, text=True)
        assert f"127.0.0.1:{proxy} (LISTEN)" in sockets.stdout and "*:" not in sockets.stdout, sockets.stdout
        process.stdin.write("close\n")
        process.stdin.flush()
        assert process.stdout.readline().strip() == f"CLOSED {iteration}"
        with socket.socket() as connection:
            assert connection.connect_ex(("127.0.0.1", int(proxy))) != 0
        print(f"PASS transport {iteration}: authenticated SSH SOCKS, original Host/path/query, two ports, loopback-only listener and cleanup", flush=True)
    assert process.wait(timeout=5) == 0, process.stderr.read()
    assert "direct-tcpip" in fixture.ssh_log.read_text()
    bad = directory / "untrusted_config"
    bad.write_text(fixture.config.read_text().replace(str(fixture.directory / "known_hosts"), str(directory / "empty_hosts")))
    rejected = subprocess.run([str(binary), str(fixture.ssh_port)], cwd=ROOT,
                              env={**environment, "ZSHELL_SSH_CONFIG_FILE": str(bad)}, capture_output=True, timeout=8)
    assert rejected.returncode != 0 and b"READY" not in rejected.stdout
    print("PASS transport: untrusted host key rejected", flush=True)


def compile_app_probe(directory, derived_data):
    products = derived_data / "Build/Products/Debug"
    library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
    if not library.is_file():
        raise RuntimeError(f"Build Debug in {derived_data} first")
    binary = directory / "browser-probe"
    arguments = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                 "-target", f"{platform.machine()}-apple-macos15.6", "-module-cache-path", str(directory / "AppModuleCache"),
                 "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
    for modulemap in (derived_data / "Build/Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"), "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"),
                  str(library), "-Xlinker", "-rpath", "-Xlinker", str(products), "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
                  str(ROOT / "mac/tests/BrowserRemoteRoutingTests.swift"), "-o", str(binary)]
    run(*arguments)
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path)
    parser.add_argument("--artifacts", type=Path)
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="zshell-browser-remote-", dir="/tmp") as temporary:
        directory = Path(temporary)
        fixture_directory = directory / "fixture"
        fixture_directory.mkdir()
        fixture = Fixture(fixture_directory)
        try:
            with fixture:
                verify_transport(directory, fixture)
                if options.derived_data:
                    binary = compile_app_probe(directory, options.derived_data.resolve())
                    for backend in ("ghostty", "alacritty"):
                        home = directory / backend
                        home.mkdir()
                        config = home / ".config/zshell-dev/config.toml"
                        config.parent.mkdir(parents=True)
                        config.write_text('ai.enabled = false\nterminal.backend = "' + backend + '"\n')
                        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
                        environment.update({"CFFIXED_USER_HOME": str(home), "HOME": str(home),
                                            "ZSHELL_SSH_CONFIG_FILE": str(fixture.config), "ZSHELL_SSH_AGENT_RESOLVED": "1",
                                            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux")})
                        arguments = [str(binary), backend, str(fixture.ssh_port), str(fixture.primary.server_port),
                                     str(fixture.secondary.server_port), str(fixture.loopback4.server_port)]
                        if options.artifacts:
                            arguments.append(str(options.artifacts.resolve()))
                        log_offset = fixture.ssh_log.stat().st_size
                        request_offset = len(fixture.requests)
                        # cfprefsd ignores CFFIXED_USER_HOME, so drop the probe's saved session.
                        subprocess.run(["/usr/bin/defaults", "delete", binary.name], capture_output=True)
                        try:
                            run(*arguments, env=environment, timeout=120)
                        finally:
                            subprocess.run(["/usr/bin/defaults", "delete", binary.name], capture_output=True)
                        with fixture.ssh_log.open("rb") as log:
                            log.seek(log_offset)
                            forwarded = log.read().decode(errors="replace")
                        targets = re.findall(r"server_request_direct_tcpip:.*target (\S+) port (\d+)", forwarded)
                        assert targets and {host for host, _ in targets} == {"localhost", "127.0.0.1", "::1"}, targets
                        for port in (fixture.primary.server_port, fixture.secondary.server_port):
                            assert str(port) in {port for _, port in targets}, forwarded
                            assert any(request[2] == f"zshell-remote.localhost:{port}"
                                       for request in fixture.requests[request_offset:]), fixture.requests[request_offset:]
                        paths = {request[1] for request in fixture.requests[request_offset:]}
                        favicons = [request for request in fixture.requests[request_offset:]
                                    if request[1].startswith("/favicon-target.png?via=zshell-remote.localhost:")]
                        assert favicons and all(request[2].startswith("127-0-0-1.zshell-remote.localhost:") for request in favicons), favicons
                        assert {"/script.js", "/dynamic.js", "/pixel.png", "/frame", "/api?cross=port", "/socket?hmr=1",
                                f"/api?early={backend}", f"/socket?early={backend}",
                                f"/api?early-xhr={backend}", f"/pixel.png?early={backend}"} <= paths, paths
                        marker = f"/must-not-reach-local-{backend}"
                        marker_requests = [request for request in fixture.requests[request_offset:] if request[1] == marker]
                        assert len(marker_requests) == 1, marker_requests
                        blocked = {f"/blocked-fetch-{backend}", f"/socket?blocked={backend}", f"/srcset-{backend}"}
                        assert paths.isdisjoint(blocked), paths.intersection(blocked)
        finally:
            fixture.__exit__()


if __name__ == "__main__":
    main()
