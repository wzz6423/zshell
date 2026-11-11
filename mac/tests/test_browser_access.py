"""Compile production browser sharing with the existing bridge; keep all state disposable."""

import argparse
import base64
from pathlib import Path
import json
import os
import queue
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[2]


class WebSocket:
    def __init__(self, url, context=None, origin=None):
        from urllib.parse import urlparse
        endpoint = urlparse(url)
        self.socket = socket.create_connection((endpoint.hostname, endpoint.port), timeout=3)
        self.socket.settimeout(3)
        if context:
            self.socket = context.wrap_socket(self.socket, server_hostname=endpoint.hostname)
        key = "dGhlIHNhbXBsZSBub25jZQ=="
        head = (f"GET /terminal HTTP/1.1\r\nHost: {endpoint.netloc}\r\n"
                f"Origin: {origin or url.rstrip('/')}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n")
        self.socket.sendall(head.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.socket.recv(1)
            if not chunk:
                break
            response += chunk
        self.upgraded = b" 101 " in response

    def send(self, payload, binary=False):
        if isinstance(payload, dict):
            payload = json.dumps(payload).encode()
        elif isinstance(payload, str):
            payload = payload.encode()
        mask = os.urandom(4)
        length = len(payload)
        head = bytes([0x82 if binary else 0x81, 0x80 | length]) if length < 126 else bytes([0x82 if binary else 0x81, 0xfe]) + struct.pack(">H", length)
        self.socket.sendall(head + mask + bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))

    def read(self, count):
        result = b""
        while len(result) < count:
            chunk = self.socket.recv(count - len(result))
            if not chunk:
                raise EOFError("WebSocket closed")
            result += chunk
        return result

    def receive(self):
        first, second = self.read(2)
        length = second & 127
        if length == 126:
            length = struct.unpack(">H", self.read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self.read(8))[0]
        payload = self.read(length)
        if first & 15 == 9:
            self.socket.sendall(bytes([0x8a, 0x80 | len(payload)]) + bytes(4) + payload)
            return self.receive()
        return (first & 15, payload)

    def expect(self, kind):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            opcode, payload = self.receive()
            if opcode == 1:
                value = json.loads(payload)
                if value.get("type") == "reset":
                    self.stream = value["stream"]
                if value.get("type") == kind:
                    return value
            elif opcode == 2:
                self.send({"type": "ack", "stream": self.stream, "bytes": len(payload)})
        raise AssertionError(f"Did not receive {kind}")

    def close(self):
        self.socket.close()

    def expect_closed(self):
        deadline = time.monotonic() + 15
        received = 0
        while time.monotonic() < deadline:
            try:
                opcode, payload = self.receive()
                received += len(payload)
                if opcode == 8:
                    return
            except (EOFError, ConnectionError):
                return
            except TimeoutError:
                continue
        raise AssertionError(f"WebSocket stayed connected after receiving {received} bytes")


class GUIAttachment:
    """Use the production GUI's Unix attachment without a second renderer."""
    def __init__(self, path, session):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(3)
        self.socket.connect(str(path))
        request = json.dumps({"version": 2, "id": "probe", "method": "attach", "params": {"id": session}}).encode()
        self.socket.sendall(struct.pack(">I", len(request)) + request)
        length = struct.unpack(">I", self.read(4))[0]
        assert json.loads(self.read(length))["ok"]

    def read(self, count):
        value = b""
        while len(value) < count:
            chunk = self.socket.recv(count - len(value))
            if not chunk:
                raise EOFError("GUI attachment closed")
            value += chunk
        return value

    def close(self):
        self.socket.close()


def production_fragments(directory):
    protocol = (ROOT / "mac/zshell/ZshellAutomationProtocol.swift").read_text()
    (directory / "JSON.swift").write_text(protocol[:protocol.index("struct ZshellAutomationRequest:")])
    remote = (ROOT / "mac/zshell/RemoteSSH.swift").read_text()
    runner = remote[remote.index("nonisolated struct BoundedProcessOutput:"):remote.index("nonisolated struct OpenSSHTransport")]
    runner += remote[remote.index("private nonisolated final class BoundedOutputCollector:"):]
    (directory / "Runner.swift").write_text("import Foundation\nimport Darwin\n" + runner)
    (directory / "Support.swift").write_text("import Foundation\nnonisolated enum CLIError: Error { case message(String) }\nnonisolated enum AppLocalization { static let current = Selection(); struct Selection { let identifier = \"en\" } }\n")


def compile_harness(directory, library):
    production_fragments(directory)
    common = ["xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor",
              "-module-cache-path", str(directory / "modules"), "-import-objc-header",
              str(ROOT / "mac/Vendor/alacritty-bridge/include/zshell_alacritty.h"),
              str(directory / "JSON.swift"), str(directory / "Runner.swift"), str(directory / "Support.swift")]
    sources = ["PTYMuxObserverFrame", "PTYMux", "PTYMuxSession", "PTYMuxSessionStore", "PersistentTerminalState",
               "PersistentCLIConnection", "ProcessWorkingDirectory", "BrowserAccessProtocol", "BrowserAccessAuthorization",
               "BrowserAccessCertificate", "BrowserAccessMuxBridge", "BrowserAccessServer"]
    frameworks = ["-framework", "Metal", "-framework", "CoreGraphics", "-framework", "CoreText",
                  "-framework", "AppKit", "-framework", "IOSurface"]
    binary = directory / "network-harness"
    subprocess.run(common + [str(ROOT / "mac/zshell" / (name + ".swift")) for name in sources]
                   + [str(ROOT / "mac/tests/BrowserAccessNetworkHarness.swift"), str(library)]
                   + frameworks + ["-o", str(binary)], check=True)
    security = directory / "security-harness"
    subprocess.run(common + [str(ROOT / "mac/zshell" / (name + ".swift")) for name in sources]
                   + [str(ROOT / "mac/tests/BrowserAccessTests.swift"), str(library)]
                   + frameworks + ["-o", str(security)], check=True)
    subprocess.run([str(security), str(directory / "security")], check=True, timeout=30)
    return binary


def check_network(binary, directory, interface, port):
    state = directory / "network"
    state.mkdir()
    environment = dict(os.environ, ZSHELL_PTY_MUX_DIRECTORY=str(state / "mux"))
    process = subprocess.Popen([str(binary), str(state), str(ROOT / "mac/zshell/BrowserAccessWeb"), interface, str(port)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
    events = queue.Queue()
    threading.Thread(target=lambda: [events.put(json.loads(line)) for line in process.stdout], daemon=True).start()

    def event(kind, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = events.get(timeout=deadline - time.monotonic())
            if value.get("type") == kind:
                return value
        raise AssertionError(kind)

    def command(value):
        process.stdin.write(value + "\n")
        process.stdin.flush()

    sockets = []
    try:
        endpoint = event("endpoint")
        sessions = event("sessions")["ids"]
        local = endpoint["url"].rstrip("/")
        remote = endpoint["remoteURL"].rstrip("/")
        url = remote or local
        context = None
        if remote:
            with urllib.request.urlopen(local + "/certificate.pem", timeout=5) as response:
                pem = response.read().decode()
            context = ssl.create_default_context(cadata=pem)
            from urllib.parse import urlparse
            parsed = urlparse(remote)
            try:
                probe = socket.create_connection(("127.0.0.1", parsed.port), timeout=1)
            except OSError:
                pass
            else:
                probe.close()
                raise AssertionError("LAN listener also bound localhost")

        def post(path, body):
            request = urllib.request.Request(url + path, data=json.dumps(body).encode(), method="POST",
                headers={"Content-Type": "application/json", "Origin": url})
            with urllib.request.urlopen(request, context=context, timeout=5) as response:
                return json.load(response)

        def inspect(session):
            command("inspect " + session)
            return event("inspected")["info"]

        denied = post("/api/pair", {"name": "Denied client"})
        command("deny " + event("pairings")["requests"][0]["id"])
        event("denied")
        assert post("/api/pair/status", {"ticket": denied["ticket"]})["state"] == "denied"

        pairing = post("/api/pair", {"name": "Network Probe 中文"})
        assert post("/api/pair/status", {"ticket": pairing["ticket"]})["state"] == "pending"
        pending = event("pairings")["requests"][0]
        assert pending["code"] == pairing["code"]
        command("approve " + pending["id"])
        assert not event("approved")["error"]
        token = post("/api/pair/status", {"ticket": pairing["ticket"]})["token"]
        wrong_origin = WebSocket(url, context=context, origin="https://evil.example")
        assert not wrong_origin.upgraded
        wrong_origin.close()
        unauthorized = WebSocket(url, context=context)
        assert unauthorized.upgraded
        unauthorized.send(b"printf UNAUTHORIZED > unauthorized-input\r", binary=True)
        unauthorized.expect_closed()
        unauthorized.close()
        assert not (state / "unauthorized-input").exists()
        invalid = WebSocket(url, context=context)
        invalid.send({"type": "authenticate", "token": "a" * 64})
        invalid.expect_closed()
        invalid.close()

        def authenticated(count=2):
            ws = WebSocket(url, context=context)
            sockets.append(ws)
            assert ws.upgraded
            ws.send({"type": "authenticate", "token": token})
            ws.expect("authenticated")
            values = ws.expect("sessions")["sessions"]
            if not values:
                values = ws.expect("sessions")["sessions"]
            assert len(values) == count
            return ws

        ws = authenticated()
        ws.send({"type": "select", "session": sessions[0]})
        ws.expect("ready")
        pid = inspect(sessions[0])["pid"]
        gui = GUIAttachment(state / "mux/control.sock", sessions[0])
        sockets.append(gui)
        ws.send("printf '\\033[31m\\344\\270\\255\\346\\226\\207 \\342\\234\\223\\033[0m\\n'\r", binary=True)
        output = b""
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and "中文 ✓".encode() not in output:
            opcode, payload = ws.receive()
            if opcode == 2:
                output += payload
                ws.send({"type": "ack", "stream": ws.stream, "bytes": len(payload)})
        assert "中文 ✓".encode() in output
        assert b"\x1b[31m" in output
        gui_output = b""
        while "中文 ✓".encode() not in gui_output:
            gui_output += gui.socket.recv(16384)
        assert inspect(sessions[0])["pid"] == pid
        gui.close()
        ws.send({"type": "resize", "columns": 101, "rows": 37})
        size = ws.expect("size")
        assert size["columns"] == 101 and size["rows"] == 37
        ws.send({"type": "select", "session": sessions[1]})
        ws.expect("ready")
        ws.close()
        ws = authenticated()
        ws.send({"type": "select", "session": sessions[0]})
        ws.expect("ready")
        assert inspect(sessions[0])["pid"] == pid
        command("restart")
        ws.expect_closed()
        endpoint = event("endpoint")
        event("restarted")
        assert endpoint["url"].rstrip("/") == local, ("Local origin changed after restart", local, endpoint)
        assert endpoint["remoteURL"].rstrip("/") == remote
        ws = authenticated()
        ws.send({"type": "select", "session": sessions[0]})
        ws.expect("ready")
        assert inspect(sessions[0])["pid"] == pid
        ws.send({"type": "ack", "stream": "00000000-0000-0000-0000-000000000000", "bytes": 1})
        ws.send({"type": "select", "session": sessions[1]})
        ws.expect("ready")
        command("terminate " + sessions[1])
        event("terminated")
        ws.expect("unavailable")
        assert not inspect(sessions[1])["running"]
        ws.send({"type": "select", "session": sessions[0]})
        ws.expect("ready")
        # Read without ACK until the production credit limit disconnects this
        # slow client. The shell finishes and remains responsive for reconnect.
        ws.send("/usr/bin/awk 'BEGIN {for(i=0;i<200000;i++)print \"xxxxxxxx\"}'\r", binary=True)
        try:
            ws.expect_closed()
        except AssertionError:
            print("Slow probe terminal tail:", base64.b64decode(inspect(sessions[0])["tailBase64"])[-1000:].decode(errors="replace"))
            raise
        ws.close()
        assert inspect(sessions[0])["running"]
        ws = authenticated(count=1)
        ws.send({"type": "select", "session": sessions[0]})
        ws.expect("ready")
        assert inspect(sessions[0])["pid"] == pid
        command("revoke")
        assert not event("revoked")["error"]
        ws.expect_closed()
        revo = WebSocket(url, context=context)
        revo.send({"type": "authenticate", "token": token})
        revo.expect_closed()
        revo.close()
        command("stop")
        event("stopped")
        from urllib.parse import urlparse
        for value in [local, remote] if remote else [local]:
            parsed = urlparse(value)
            try:
                probe = socket.create_connection((parsed.hostname, parsed.port), timeout=1)
            except OSError:
                pass
            else:
                probe.close()
                raise AssertionError("listener remained open after disabling")
        assert not (state / "unauthorized-input").exists()
        print("Production network probe passed: pairing/denial, verified TLS, Origin/token/input rejection, simultaneous GUI/Unicode/ANSI, resize, same-PID reconnect, stable origin/token across restart, pane termination, slow-client backpressure, revoke, listener shutdown.")
    finally:
        for ws in sockets:
            ws.close()
        if process.poll() is None:
            command("quit")
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=3)
        if process.returncode:
            print(process.stderr.read())
        assert process.returncode == 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge-library", type=Path, required=True, help="Existing libzshell_alacritty.a; this probe never runs Cargo or Xcode.")
    parser.add_argument("--interface", default="loopback", help="Explicit private interface ID, e.g. en0|192.168.0.10; loopback by default.")
    parser.add_argument("--port", type=int, default=37443)
    arguments = parser.parse_args()
    assert arguments.bridge_library.is_file()
    # Darwin's sockaddr_un has a short path limit; the default macOS temporary
    # directory leaves too little space for the daemon's control.sock.
    with tempfile.TemporaryDirectory(prefix="zshell-browser-access-", dir="/tmp") as temporary:
        directory = Path(temporary)
        binary = compile_harness(directory, arguments.bridge_library.resolve())
        check_network(binary, directory, arguments.interface, arguments.port)


if __name__ == "__main__":
    main()
