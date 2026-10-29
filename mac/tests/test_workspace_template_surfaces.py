"""Exercise workspace templates against real AppKit, PTYs and WebKit.

Build Debug first, then set ZSHELL_TEST_DERIVED_DATA to that build. Both
terminal backends use disposable homes, preferences and browser state. Windows
stay offscreen unless ZSHELL_TEMPLATE_TEST_VISIBLE=1 is set while the GUI slot
is available. Test binaries and state are removed after each run.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import stat
import subprocess
import tempfile
import threading
import uuid


ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
PRODUCTS = BUILD / "Products/Debug"
APP = PRODUCTS / "zshell Debug.app"
LIBRARY = APP / "Contents/MacOS/zshell.debug.dylib"
if not LIBRARY.is_file():
    raise SystemExit(f"Build the Debug app in {BUILD.parent} first.")


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>Template fixture</title><h1>Template fixture</h1>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix="zshell-template-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    bundle = temporary / "WorkspaceTemplateTests.app/Contents"
    binary = bundle / "MacOS/WorkspaceTemplateTests"
    binary.parent.mkdir(parents=True)
    bundle_identifier = "sh.zshell.template-test." + uuid.uuid4().hex
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_identifier,
        "CFBundleExecutable": binary.name,
        "CFBundleDevelopmentRegion": "en",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
    }))
    (bundle / "Resources").symlink_to(APP / "Contents/Resources")
    command = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(PRODUCTS), "-I", str(PRODUCTS / "include"), "-F", str(PRODUCTS),
    ]
    for modulemap in (BUILD / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        command += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in (
        "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
    ):
        path = ROOT / "mac/Vendor" / include
        command += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    command += [
        "-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"),
        str(LIBRARY), "-Xlinker", "-rpath", "-Xlinker", str(PRODUCTS),
        "-Xlinker", "-rpath", "-Xlinker", str(LIBRARY.parent),
        str(ROOT / "mac/tests/WorkspaceTemplateSurfaceTests.swift"),
        str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary),
    ]
    subprocess.run(command, cwd=ROOT, check=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    try:
        for backend in ("alacritty", "ghostty"):
            home = temporary / backend
            home.mkdir()
            (home / "tmp").mkdir()
            config = home / ".config/zshell-dev"
            config.mkdir(parents=True)
            (config / "config.toml").write_text("[ai]\nenabled = false\n")
            # Ghostty's login launcher can reset HOME before reading zsh files.
            startup = 'export HOME="$CFFIXED_USER_HOME"\nexport ZDOTDIR="$HOME"\nHISTFILE=/dev/null\n'
            (home / ".zshenv").write_text(startup)
            (home / ".zshrc").write_text(startup + "PROMPT='TEMPLATE-READY> '; RPROMPT=''\n")
            (home / ".zprofile").write_text("")
            (home / ".zlogin").write_text("")
            results = home / "results"
            results.mkdir()
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update({
                "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                "TMPDIR": str(home / "tmp") + "/", "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty"),
                "ZSHELL_TEMPLATE_TEST_VISIBLE": os.environ.get("ZSHELL_TEMPLATE_TEST_VISIBLE", "0"),
            })
            print(f"RUN workspace template surfaces {backend}", flush=True)
            try:
                with subprocess.Popen([
                    str(binary), backend, str(home), f"http://127.0.0.1:{server.server_port}", str(results),
                ], cwd=ROOT, env=environment, start_new_session=True) as fixture:
                    print(f"PROCESS backend={backend} pid={fixture.pid}", flush=True)
                    try:
                        code = fixture.wait(timeout=120)
                        if code != 0:
                            raise subprocess.CalledProcessError(code, fixture.args)
                    finally:
                        if fixture.poll() is None:
                            os.killpg(fixture.pid, signal.SIGTERM)
                            try:
                                fixture.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                os.killpg(fixture.pid, signal.SIGKILL)
                                fixture.wait()
                        for socket in Path("/tmp").glob(f"zshell-{os.getuid()}-{fixture.pid}-*.sock"):
                            if stat.S_ISSOCK(socket.lstat().st_mode):
                                socket.unlink()
                if artifacts := os.environ.get("ZSHELL_TEMPLATE_TEST_ARTIFACTS"):
                    destination = Path(artifacts)
                    destination.mkdir(parents=True, exist_ok=True)
                    for screenshot in results.glob("*.png"):
                        shutil.copy2(screenshot, destination / screenshot.name)
            finally:
                cli = [str(APP / "Contents/MacOS/zshell"), "+pty-mux"]
                listing = subprocess.run(cli + ["list"], cwd=ROOT, env=environment,
                                         capture_output=True, text=True, timeout=10)
                if listing.returncode == 0:
                    for session in json.loads(listing.stdout):
                        subprocess.run(cli + ["terminate", session["id"]], cwd=ROOT,
                                       env=environment, capture_output=True, timeout=10)
                    subprocess.run(cli + ["shutdown"], cwd=ROOT, env=environment,
                                   capture_output=True, timeout=10, check=True)
    finally:
        server.shutdown()
        server.server_close()
        serving.join(timeout=5)
        subprocess.run(["/usr/bin/defaults", "delete", bundle_identifier],
                       capture_output=True, timeout=10)
        (Path.home() / "Library/Preferences" / f"{bundle_identifier}.plist").unlink(missing_ok=True)
