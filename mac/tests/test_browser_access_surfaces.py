"""Exercise Browser Access with the built app's real terminal backends and Settings.

Build Debug first, then pass --derived-data. This probe links the existing
production dylib, keeps windows off every display, and removes all test state.
It does not run Xcode or Cargo or alter an installed application's preferences.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import uuid
from urllib.parse import urlparse
import sys

sys.dont_write_bytecode = True
from test_browser_access import WebSocket


ROOT = Path(__file__).resolve().parents[2]


def compile_probe(directory, derived_data):
    build = derived_data / "Build"
    products = build / "Products/Debug"
    apps = [path for path in products.glob("*.app") if (path / "Contents/MacOS/zshell.debug.dylib").is_file()]
    if len(apps) != 1:
        raise RuntimeError(f"Expected one Debug app with zshell.debug.dylib in {products}")
    application = apps[0]
    library = application / "Contents/MacOS/zshell.debug.dylib"
    contents = directory / "BrowserProbe.app/Contents"
    binary = contents / "MacOS/browser-probe"
    binary.parent.mkdir(parents=True)
    resources = contents / "Resources"
    shutil.copytree(application / "Contents/Resources", resources)
    info = plistlib.loads((application / "Contents/Info.plist").read_bytes())
    domain = "sh.zshell.browser-surface-probe." + uuid.uuid4().hex
    info.update(CFBundleIdentifier=domain, CFBundleExecutable=binary.name, CFBundleName="Browser Surface Probe", LSUIElement=True)
    for key in ("CFBundleURLTypes", "NSServices", "LSBackgroundOnly"):
        info.pop(key, None)
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    # Resources must match the current source after localization-only edits.
    subprocess.run(["xcrun", "xcstringstool", "compile", str(ROOT / "mac/zshell/Localizable.xcstrings"),
                    "--output-directory", str(resources)], check=True)
    arguments = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target",
                 f"{platform.machine()}-apple-macos15.6", "-module-cache-path", str(directory / "modules"),
                 "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
    for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
                  "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
                  "-Xlinker", "-rpath", "-Xlinker", str(products),
                  "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
                  str(ROOT / "mac/tests/BrowserAccessSurfaceHarness.swift"),
                  str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary)]
    subprocess.run(arguments, cwd=ROOT, check=True)
    return binary, domain


def probe(binary, directory, backend, occupied=False):
    directory.mkdir()
    home = directory / "home"
    config = home / ".config/zshell-dev/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text("ai.enabled = false\nterminal.restore-history = false\nterminal.notify-on-error = false\n")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                       ZSHELL_PTY_MUX_DIRECTORY=str(directory / "mux"), ZSHELL_SSH_AGENT_RESOLVED="1")
    # Keep every fallback below the OS ephemeral range used by test connections.
    reserved = []
    for _ in range(100):
        local_port = 24_000 + int(uuid.uuid4().hex[:4], 16) % 16_000
        try:
            for candidate in range(local_port, local_port + 8):
                reservation = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                reserved.append(reservation)
                reservation.bind(("127.0.0.1", candidate))
            break
        except OSError:
            for reservation in reserved:
                reservation.close()
            reserved.clear()
    else:
        raise AssertionError("No free deterministic localhost port range")
    listener = reserved[0]
    for reservation in reserved[1:]:
        reservation.close()
    if occupied:
        listener.listen()
    else:
        listener.close()
    port = local_port - 1 if local_port > 1024 else 65535
    environment["ZSHELL_BROWSER_PROBE_PORT"] = str(port)
    log = (directory / "process.log").open("w")
    process = subprocess.Popen([str(binary), str(directory), backend], cwd=ROOT, env=environment, stdout=log, stderr=log)
    sockets = []

    def command(value):
        (directory / "command").write_text(value + "\n")

    def status():
        try:
            return json.loads((directory / "status.json").read_text())
        except (OSError, ValueError):
            return {}

    def wait(predicate, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError((directory / "process.log").read_text())
            current = status()
            if predicate(current):
                return current
            time.sleep(0.05)
        raise AssertionError(status())

    try:
        state = wait(lambda state: state.get("url") and state.get("pid", 0) > 0)
        assert state["previousPersistent"] == "" and not state["preserve"]
        endpoint = state["url"].rstrip("/")
        expected_port = local_port + 1 if occupied else local_port
        assert urlparse(endpoint).port == expected_port, (endpoint, expected_port)

        def post(path, body):
            import urllib.request
            request = urllib.request.Request(endpoint + path, data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json", "Origin": endpoint}, method="POST")
            with urllib.request.urlopen(request, timeout=3) as response:
                return json.load(response)

        pair = post("/api/pair", {"name": "Browser Surface 中文"})
        wait(lambda state: bool(state.get("pending")))
        command("approve")
        wait(lambda state: bool(state.get("clients")))
        token = post("/api/pair/status", {"ticket": pair["ticket"]})["token"]

        def connect():
            connection = WebSocket(endpoint)
            sockets.append(connection)
            connection.send({"type": "authenticate", "token": token})
            connection.expect("authenticated")
            sessions = connection.expect("sessions")["sessions"]
            if not sessions:
                sessions = connection.expect("sessions")["sessions"]
            assert state["first"] in [session["id"] for session in sessions]
            connection.send({"type": "select", "session": state["first"]})
            connection.expect("ready")
            return connection

        connection = connect()
        marker = "browser-" + backend + "-中文-✓"
        # Encode Chinese as octal so observing the command's echo cannot pass.
        literal = "".join(f"\\{value:03o}" for value in marker.encode())
        connection.send(f"printf '\\033[32m{literal}\\033[0m\\n'\r", binary=True)
        wait(lambda state: marker in state.get("text", ""))
        assert status()["pid"] == state["pid"]
        connection.close()
        connection = connect()
        assert status()["pid"] == state["pid"]
        command("layout")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not (directory / "layout.json").exists():
            time.sleep(0.1)
        layout = json.loads((directory / "layout.json").read_text())
        assert len(layout) == 51 and all(not sample["invalid"] for sample in layout), layout
        command("close")
        wait(lambda state: state.get("second") == "")
        command("sleep")
        connection.expect_closed()
        wait(lambda state: state.get("url") == "")
        command("wake")
        endpoint = wait(lambda state: bool(state.get("url")))["url"].rstrip("/")
        assert endpoint == state["url"].rstrip("/"), "Wake changed localhost origin"
        connection = connect()
        for operation in ("retry", "restart"):
            handled = status()["handledCommands"]
            command(operation)
            connection.expect_closed()
            endpoint = wait(lambda state: state.get("handledCommands", 0) > handled and bool(state.get("url")))["url"].rstrip("/")
            assert endpoint == state["url"].rstrip("/"), operation
            connection = connect()
        assert len(status()["clients"]) == 1, "Restart must reuse the existing authorization"
        command("revoke")
        connection.expect_closed()
        wait(lambda state: not state.get("clients"))
        pair = post("/api/pair", {"name": "Browser Disable"})
        wait(lambda state: bool(state.get("pending")))
        command("approve")
        wait(lambda state: bool(state.get("clients")))
        token = post("/api/pair/status", {"ticket": pair["ticket"]})["token"]
        connection = connect()
        command("disable")
        connection.expect_closed()
        wait(lambda state: not state.get("enabled") and state.get("url") == "")
        parsed = urlparse(endpoint)
        try:
            with socket.create_connection((parsed.hostname, parsed.port), timeout=1):
                raise AssertionError("Browser listener stayed open")
        except OSError:
            pass
        command("restart")
        wait(lambda state: bool(state.get("clients")) and not state["enabled"] and not state["url"])
        command("clients-ui")
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not (directory / "clients-ui.json").exists():
            time.sleep(0.05)
        assert all(json.loads((directory / "clients-ui.json").read_text()).values()), "Saved clients must be revocable in the real disabled Settings pane"
        command("revoke")
        wait(lambda state: not state.get("clients"))
        command("state-race")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not (directory / "state-race.json").exists():
            time.sleep(0.1)
        races = json.loads((directory / "state-race.json").read_text())
        details = directory / "state-race-detail.json"
        assert len(races) == 7 and all(races.values()), (races, details.read_text() if details.exists() else "")
        print(f"PASS {backend}: real browser input, stable token/origin across sleep/retry/restart, old pane intact, 17-language layout, pane close/revoke/disable, occupied-port={occupied}, disabled saved clients/revoke and delayed-state races")
    finally:
        for connection in sockets:
            connection.close()
        if process.poll() is None:
            command("quit")
            try:
                process.wait(timeout=6)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=3)
        log.close()
        listener.close()
        if process.returncode:
            print((directory / "process.log").read_text())
        assert process.returncode == 0


def check_controller_capability(binary, directory, mode="old"):
    directory.mkdir()
    home = directory / "home"
    home.mkdir()
    mux = directory / "mux"
    mux.mkdir(mode=0o700)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(mux / "control.sock"))
    lock = (mux / "daemon.lock").open("w")
    if mode == "startup":
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        listener.close()
    else:
        listener.listen()
        listener.settimeout(0.1)
    methods = []
    stopped = threading.Event()
    recovered = threading.Event()

    def read(connection, count):
        value = b""
        while len(value) < count:
            chunk = connection.recv(count - len(value))
            if not chunk:
                raise EOFError("Old daemon request closed")
            value += chunk
        return value

    def serve():
        if mode == "startup":
            return
        while not stopped.is_set():
            try:
                connection, _ = listener.accept()
            except TimeoutError:
                continue
            with connection:
                try:
                    count = struct.unpack(">I", read(connection, 4))[0]
                except EOFError:
                    continue
                request = json.loads(read(connection, count))
                methods.append(request["method"])
                if mode == "timeout" and request["method"] == "capabilities" and not recovered.is_set():
                    stopped.wait(0.4)
                    continue
                current = recovered.is_set()
                ok = current and request["method"] == "capabilities" or request["method"] == "list"
                response = json.dumps({"version": 2, "id": request["id"], "ok": ok,
                    "result": {"observe": True} if ok and request["method"] == "capabilities" else [{"running": True}] if ok else None,
                    "error": None if ok else {"code": "unknown_method", "message": "unsupported"}}).encode()
                connection.sendall(struct.pack(">I", len(response)) + response)

    worker = threading.Thread(target=serve)
    worker.start()
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                       ZSHELL_PTY_MUX_DIRECTORY=str(mux), ZSHELL_SSH_AGENT_RESOLVED="1")
    process = subprocess.Popen([str(binary), str(directory), "capability"], cwd=ROOT, env=environment,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(process.stdout.read())
            try:
                status = json.loads((directory / "status.json").read_text())
            except (OSError, ValueError):
                status = {}
            if mode == "old" and not status.get("enabled", True) and "current session service" in status.get("error", ""):
                break
            if mode != "old" and status.get("enabled") and "Click Retry" in status.get("error", ""):
                break
            time.sleep(0.05)
        else:
            raise AssertionError(status)
        time.sleep(0.5)
        status = json.loads((directory / "status.json").read_text())
        if mode == "old":
            assert not status["enabled"] and not status["url"] and "current session service" in status["error"], status
            assert "capabilities" in methods and "list" in methods
        else:
            assert status["enabled"] and not status["url"] and "Click Retry" in status["error"], status
            if mode == "startup":
                fcntl.flock(lock, fcntl.LOCK_UN)
                (mux / "control.sock").unlink()
            recovered.set()
            (directory / "command").write_text("retry\n")
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                status = json.loads((directory / "status.json").read_text())
                if status.get("url") and not status.get("error"):
                    break
                time.sleep(0.05)
            else:
                raise AssertionError(status)
            assert status["enabled"], status
        assert "shutdown" not in methods and "terminateAll" not in methods
        print("PASS controller: old live daemon keeps jobs, master switch closes, error stays visible" if mode == "old"
              else f"PASS controller: {mode} keeps Browser Access enabled, reports Retry, and recovers on Retry")
    finally:
        (directory / "command").write_text("quit\n")
        try:
            process.wait(timeout=6)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=3)
        stopped.set()
        worker.join(timeout=2)
        listener.close()
        lock.close()
        if process.returncode:
            print(process.stdout.read())
        assert process.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--backend", choices=("alacritty", "ghostty"), action="append")
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="zshell-browser-surfaces-", dir="/tmp") as temporary:
        directory = Path(temporary)
        binary, domain = compile_probe(directory, arguments.derived_data.resolve())
        try:
            check_controller_capability(binary, directory / "capability")
            for mode in ("startup", "timeout"):
                check_controller_capability(binary, directory / mode, mode)
            for backend in arguments.backend or ("alacritty", "ghostty"):
                probe(binary, directory / backend, backend, occupied=backend == "ghostty")
        finally:
            # cfprefsd can persist the probe's unique domain outside its HOME.
            plist = Path.home() / "Library/Preferences" / (domain + ".plist")
            subprocess.run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            plist.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
