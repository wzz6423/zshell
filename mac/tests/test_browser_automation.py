"""Verify browser URL policy and the compiled CLI's JSON wire contract without a GUI.

Build Debug first, then set ZSHELL_TEST_DERIVED_DATA for an isolated build:
    ZSHELL_TEST_DERIVED_DATA=/tmp/zshell-build python3 mac/tests/test_browser_automation.py
Pass --webkit to verify the first automated navigation with a real srcdoc frame
in an invisible native test window. Project/window isolation requires the app.
"""

import base64
import http.server
import json
import os
from pathlib import Path
import platform
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import uuid

root = Path(__file__).resolve().parents[2]
build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", root / "mac/build/debug"))
executable = build / "Build/Products/Debug/zshell Debug.app/Contents/MacOS/zshell"
if not executable.is_file():
    raise SystemExit(f"Build the Debug app at {build} first.")


def verify_curl_jar(temporary):
    jar = temporary / "input-cookies.txt"
    jar.write_text("# Netscape HTTP Cookie File\n#HttpOnly_example.test\tTRUE\t/\tFALSE\t0\tfixture_parent\tfixture-only\n")
    normalized = temporary / "curl-cookies.txt"
    observed = []

    class Fixture(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            observed.append("fixture_parent=" in self.headers.get("Cookie", ""))
            self.send_response(200)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        subprocess.run([
            "/usr/bin/curl", "--silent", "--show-error", "--noproxy", "*", "--max-time", "5",
            "--cookie", str(jar), "--cookie-jar", str(normalized),
            "--resolve", f"app.example.test:{server.server_port}:127.0.0.1",
            f"http://app.example.test:{server.server_port}/",
        ], check=True, capture_output=True)
        assert observed == [True]
        assert "#HttpOnly_.example.test\tTRUE\t" in normalized.read_text()
    finally:
        server.shutdown()
        worker.join(timeout=2)
        server.server_close()
    print("System curl Netscape compatibility: undotted TRUE domain sent to subdomain and normalized with HttpOnly preserved")
    return normalized


def verify_webkit(temporary):
    products = build / "Build/Products/Debug"
    library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
    binary = temporary / "navigation-tests"
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(products), "-I", str(products / "include"), "-F", str(products),
    ]
    for modulemap in (build / "Build/Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in (
        "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
    ):
        path = root / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += [
        "-I", str(root / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(root / "mac/Vendor/tree-sitter/lib/include"), str(library),
        "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
        str(root / "mac/tests/BrowserAutomationNavigationTests.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, check=True, cwd=root)

    class Fixture(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/cookie-check":
                cookie = self.headers.get("Cookie", "")
                body = json.dumps({"httpOnly": "fixture_http=" in cookie, "session": "fixture_session=" in cookie}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)
                return
            html = b'''<!doctype html><style>
html,body{margin:0;background:rgb(22,50,79)}
#red{position:absolute;left:0;top:0;width:360px;height:240px;background:rgb(220,40,60)}
#green{position:absolute;left:400px;top:260px;width:360px;height:240px;background:rgb(20,170,90)}
h1{position:absolute;top:20px;left:24px;color:white;font:30px sans-serif}
iframe,button{position:absolute;top:600px}
</style><div id="red"></div><div id="green"></div><h1>Parent document</h1>
<iframe srcdoc="<p>Child document</p>"></iframe>
<button id="blocked-frame" onclick="const f=document.createElement('iframe');f.src='zshell-browser-test://blocked';document.body.append(f)">Blocked frame</button>
<script>window.fixturePageToken='page-context';localStorage.setItem('fixture-login','fixture-only')</script>'''
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Set-Cookie", "fixture_http=fixture-only; Path=/; HttpOnly; SameSite=Strict; Max-Age=3600")
            self.send_header("Set-Cookie", "fixture_session=fixture-only; Path=/; SameSite=Lax")
            self.end_headers()
            self.wfile.write(html)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment["HOME"] = str(temporary)
        environment["CFFIXED_USER_HOME"] = str(temporary)
        environment["ZSHELL_PTY_MUX_DIRECTORY"] = str(temporary / "pty")
        config = temporary / ".config/zshell-dev/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text('ai.enabled = false\nterminal.backend = "alacritty"\n')
        arguments = [str(binary), f"http://127.0.0.1:{server.server_port}/"]
        if output := os.environ.get("ZSHELL_TEST_ARTIFACTS"):
            arguments.append(str(Path(output).resolve()))
        subprocess.run(arguments, env=environment, check=True, timeout=75)
    finally:
        server.shutdown()
        worker.join(timeout=2)
        server.server_close()


with tempfile.TemporaryDirectory(prefix="zshell-browser-test-", dir="/tmp") as directory:
    temporary = Path(directory)
    policy = temporary / "PolicyTests.swift"
    policy.write_text('''import Foundation
@main struct PolicyTests {
    @MainActor static func main() throws {
        for allowed in ["http://localhost:3000/", "http://127.0.0.1:8080/test", "http://[::1]:8080/", "https://example.com/path?q=test#result", "about:blank"] {
            _ = try BrowserAutomation.destination(allowed)
        }
        for denied in ["file:///etc/passwd", "data:text/html,hello", "javascript:alert(1)", "blob:https://example.com/1", "ftp://example.com/", "mailto:user@example.com", "https://user:password@example.com/", "localhost:3000", "about:config", "about:srcdoc", "http://", String(repeating: "x", count: 8193)] {
            do {
                _ = try BrowserAutomation.destination(denied)
                fatalError("Unexpected allowed URL: \\(denied)")
            } catch let error as BrowserAutomationError {
                precondition(error.code == "unsupported_url")
            }
        }
        precondition(BrowserAutomation.isAllowedURL(URL(string: "about:srcdoc")!, isMainFrame: false))
        for deniedChild in ["file:///etc/passwd", "custom://external", "javascript:alert(1)", "about:config"] {
            precondition(!BrowserAutomation.isAllowedURL(URL(string: deniedChild)!, isMainFrame: false))
        }
        let automation = BrowserAutomation()
        automation.restrictNavigation()
        automation.rejectNavigation()
        precondition(automation.restrictsNavigation && automation.navigationWasRejected)
        automation.releaseNavigationRestriction()
        precondition(!automation.restrictsNavigation && !automation.navigationWasRejected)
        automation.invalidateDocument()
        precondition(automation.documentRevision == 1)
        try BrowserStorageStateTests.verify()
        print("Browser URL policy: passed")
    }
}
''')
    policy_binary = temporary / "policy-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-cache-path", str(temporary / "ModuleCache"),
        str(root / "mac/zshell/ZshellAutomationProtocol.swift"),
        str(root / "mac/zshell/BrowserStorageState.swift"),
        str(root / "mac/tests/BrowserStorageStateTests.swift"),
        str(root / "mac/zshell/BrowserAutomation.swift"), str(policy),
        "-o", str(policy_binary),
    ], check=True, cwd=root)
    curl_jar = verify_curl_jar(temporary)
    subprocess.run([str(policy_binary), str(curl_jar)], check=True, cwd=root)

    socket_path = str(temporary / "cli.sock")
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(socket_path)
    listener.listen(5)
    listener.settimeout(0.1)
    stopped = threading.Event()
    requests = []
    browser_id = str(uuid.uuid4())
    pane_id = str(uuid.uuid4())
    terminal_id = str(uuid.uuid4())
    png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afoQAAAAASUVORK5CYII=")

    def serve():
        while not stopped.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            with connection:
                data = b""
                while b"\n" not in data:
                    chunk = connection.recv(8192)
                    if not chunk:
                        break
                    data += chunk
                request = json.loads(data)
                requests.append(request)
                assert request["token"] == "browser-test-capability"
                assert request["terminalID"] == terminal_id
                method = request["method"]
                if method == "browser.list":
                    result = []
                elif method == "browser.screenshot":
                    result = {"data_base64": base64.b64encode(png).decode(), "format": "png", "width": 1, "height": 1, "bytes": len(png)}
                elif method == "browser.state.save":
                    result = {"data_base64": base64.b64encode(b'{"cookies":[],"origins":[]}').decode(), "cookies": 0, "local_storage_entries": 0}
                else:
                    result = {"browser_id": browser_id, "pane_id": pane_id, "matched": True}
                connection.sendall(json.dumps({"version": 1, "id": request["id"], "ok": True, "result": result}).encode() + b"\n")

    thread = threading.Thread(target=serve)
    thread.start()
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    environment.update({
        "ZSHELL_CLI_STATE": str(temporary / "state.json"),
        "ZSHELL_CLI_TOKEN": "browser-test-cli",
        "ZSHELL_AUTOMATION_SOCKET": socket_path,
        "ZSHELL_AUTOMATION_TOKEN": "browser-test-capability",
        "ZSHELL_TERMINAL_ID": terminal_id,
        "CFFIXED_USER_HOME": directory,
    })

    def run(*arguments, succeeds=True):
        result = subprocess.run([str(executable), "+browser", *arguments], env=environment, capture_output=True, text=True, timeout=10)
        assert (result.returncode == 0) == succeeds, (arguments, result.stdout, result.stderr)
        return result

    try:
        assert "snapshot" in run("--help").stdout
        assert json.loads(run("list").stdout) == []
        run("open", "http://localhost:3000/", "--tab", "--wait")
        assert requests[-2]["method"] == "browser.open"
        assert requests[-2]["params"] == {"tab": True, "url": "http://localhost:3000/"}
        assert requests[-1]["method"] == "browser.wait"
        assert requests[-1]["params"]["browser_id"] == browser_id
        run("open", "about:blank", "--pane", pane_id, "--left", "--focus")
        assert requests[-1]["params"]["edge"] == "left"
        assert requests[-1]["params"]["focus"] is True
        run("snapshot", "--browser", browser_id, "--max-elements", "20", "--max-text", "1000")
        assert requests[-1]["params"]["max_elements"] == 20
        literal = "quotes ' \\\" and $(literal) <script> untouched"
        run("fill", "--pane", pane_id, "--selector", "#search", "--text", literal)
        assert requests[-1]["params"]["value"] == literal
        run("click", "--browser", browser_id, "--ref", "snapshot:0")
        assert requests[-1]["params"]["ref"] == "snapshot:0"
        run("wait", "--browser", browser_id, "--selector", "#result", "--state", "attached", "--timeout", "30000")
        assert requests[-1]["params"]["timeout_ms"] == 30000
        for command in ("navigate", "back", "forward", "reload", "stop", "get"):
            options = ["http://localhost:3000/next"] if command == "navigate" else []
            run(command, *options, "--browser", browser_id)
            assert requests[-1]["method"] == f"browser.{command}"
        capture = temporary / "capture.png"
        output = json.loads(run("screenshot", "--browser", browser_id, "--output", str(capture), "--width", "640").stdout)
        assert capture.read_bytes() == png
        assert stat.S_IMODE(capture.stat().st_mode) == 0o600
        assert "data_base64" not in output
        assert output["path"] == str(capture)
        run("screenshot", "--output", str(capture), succeeds=False)
        assert capture.read_bytes() == png
        symlink = temporary / "link.png"
        symlink.symlink_to(capture)
        run("screenshot", "--output", str(symlink), succeeds=False)
        assert capture.read_bytes() == png
        script = "Promise.resolve({title: document.title, literal: '$(unchanged)'})"
        run("eval", "--browser", browser_id, "--script", script, "--timeout", "1000")
        assert requests[-1]["method"] == "browser.eval"
        assert requests[-1]["params"]["script"] == script
        run("eval", "document.title", "--browser", browser_id)
        assert requests[-1]["params"]["script"] == "document.title"
        state = temporary / "private-state.json"
        exported = json.loads(run("state", "save", "--browser", browser_id, "--output", str(state)).stdout)
        assert stat.S_IMODE(state.stat().st_mode) == 0o600
        assert "data_base64" not in exported and "cookies" in exported
        run("state", "load", "--browser", browser_id, "--input", str(state))
        assert requests[-1]["method"] == "browser.state.load"
        assert base64.b64decode(requests[-1]["params"]["data_base64"]) == state.read_bytes()
        cookie_file = temporary / "cookies.txt"
        run("state", "save", "--format", "cookies", "--output", str(cookie_file))
        assert requests[-1]["params"]["format"] == "cookies"
        run("state", "save", "--output", str(state), succeeds=False)
        state_link = temporary / "state-link"
        state_link.symlink_to(state)
        run("state", "save", "--output", str(state_link), succeeds=False)
        count = len(requests)
        run("state", "load", "--input", str(state_link), succeeds=False)
        state.chmod(0o644)
        run("state", "load", "--input", str(state), succeeds=False)
        state.chmod(0o600)
        assert len(requests) == count
        oversize = temporary / "oversize"
        oversize.write_bytes(b"x" * 262145)
        oversize.chmod(0o600)
        run("state", "load", "--input", str(oversize), succeeds=False)
        fifo = temporary / "fifo"
        os.mkfifo(fifo, 0o600)
        run("state", "load", "--input", str(fifo), succeeds=False)
        for key in ("ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN", "ZSHELL_AUTOMATION_SOCKET", "ZSHELL_AUTOMATION_TOKEN", "ZSHELL_TERMINAL_ID"):
            saved = environment[key]
            environment[key] = ""
            run("eval", "document.title", succeeds=False)
            environment[key] = saved
        assert len(requests) == count
        for arguments in [
            ("eval",), ("eval", "--script", " "), ("eval", "--script", "x" * 65537),
            ("eval", "x", "--script", "y"), ("state", "save"), ("state", "load"),
            ("state", "delete"), ("state", "save", "--format", "invalid", "--output", str(state)),
            ("get", "--browser", browser_id, "--pane", pane_id),
            ("snapshot", "--timeout", "30001"), ("snapshot", "--timeout", "99"),
            ("click", "--ref", "a", "--selector", "#b"), ("fill", "--selector", "#a"),
            ("open", "--tab", "--right"), ("screenshot",), ("get", "--unknown"),
            ("get", "--browser", browser_id, "--browser", browser_id),
        ]:
            count = len(requests)
            run(*arguments, succeeds=False)
            assert len(requests) == count, arguments
        print(f"Browser CLI wire contract: passed ({len(requests)} authenticated requests; private exclusive files, bounded imports and empty capability rejection)")
    finally:
        stopped.set()
        thread.join(timeout=2)
        listener.close()
    if "--webkit" in sys.argv:
        verify_webkit(temporary)
